package engine

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

// Version 2 measures payload throughput after a bounded warm-up. It is not a
// physical-link rate. All streams share one read budget, including warm-up.
type DownloadDetails struct {
	Version           int     `json:"version"`
	Connections       int     `json:"connections"`
	ActiveConnections int     `json:"activeConnections"`
	SetupMS           float64 `json:"setupMS"`
	SampleSeconds     float64 `json:"sampleSeconds"`
	MeasuredBytes     int64   `json:"measuredBytes"`
	WarmupBytes       int64   `json:"warmupBytes"`
	EndToEndMbps      float64 `json:"endToEndMbps"`
	ShortSample       bool    `json:"shortSample"`
	PartialFailure    bool    `json:"partialFailure"`
}

type downloadResult struct {
	Mbps    *float64
	Bytes   int64
	Error   string
	Details DownloadDetails
}

func downloadTarget(raw string, budget int64) string {
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	// Do not alter signed/custom URLs. The bundled Cloudflare generator must
	// produce enough data when the user selects more than the old fixed 8 MiB.
	if u.Scheme == "https" && strings.EqualFold(u.Hostname(), "speed.cloudflare.com") && u.Path == "/__down" {
		q := u.Query()
		q.Set("bytes", strconv.FormatInt(budget, 10))
		q.Set("_nodescope", strconv.FormatInt(time.Now().UnixNano(), 10))
		u.RawQuery = q.Encode()
	}
	return u.String()
}

type downloadStats struct {
	sync.Mutex
	first, sampleStart, limitAt time.Time
	total, warmup, measured     int64
	sources                     map[int]bool
}

func download(parent context.Context, proxy C.Proxy, options Options) downloadResult {
	started := time.Now()
	ctx, cancel := context.WithTimeout(parent, time.Duration(options.DownloadSeconds)*time.Second)
	defer cancel()
	streams := options.DownloadConnections
	if streams == 0 {
		streams = 1
	}
	if streams != 1 && streams != 4 {
		return downloadResult{Error: "下载连接数必须为 1 或 4"}
	}
	var remaining atomic.Int64
	remaining.Store(options.DownloadBytes)
	var failures atomic.Int64
	stats := downloadStats{sources: map[int]bool{}}
	warmupLimit := min(int64(256<<10), options.DownloadBytes/8)
	// Reserve before reading and refund unused bytes. Concurrent reads can never
	// exceed the user's aggregate cap, even when a server ignores Range.
	reserve := func() int64 {
		for {
			old := remaining.Load()
			if old <= 0 {
				return 0
			}
			size := min(old, int64(32<<10))
			if remaining.CompareAndSwap(old, old-size) {
				return size
			}
		}
	}
	var workers sync.WaitGroup
	for worker := 0; worker < streams; worker++ {
		workers.Add(1)
		go func(index int) {
			defer workers.Done()
			client := clientFor(proxy, time.Duration(options.DownloadSeconds)*time.Second)
			defer client.CloseIdleConnections()
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, downloadTarget(options.DownloadURL, options.DownloadBytes), nil)
			if err != nil {
				failures.Add(1)
				return
			}
			req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", options.DownloadBytes-1))
			req.Header.Set("Accept-Encoding", "identity")
			req.Header.Set("Cache-Control", "no-cache, no-store")
			req.Header.Set("Pragma", "no-cache")
			response, err := client.Do(req)
			if err != nil {
				if ctx.Err() == nil {
					failures.Add(1)
				}
				return
			}
			defer response.Body.Close()
			contentType := strings.ToLower(response.Header.Get("Content-Type"))
			if (response.StatusCode != 200 && response.StatusCode != 206) ||
				(response.Header.Get("Content-Encoding") != "" && response.Header.Get("Content-Encoding") != "identity") ||
				strings.HasPrefix(contentType, "text/") || strings.Contains(contentType, "json") || strings.Contains(contentType, "xml") {
				failures.Add(1)
				return
			}
			buffer := make([]byte, 32<<10)
			for {
				if ctx.Err() != nil {
					return
				}
				reserved := reserve()
				if reserved == 0 {
					return
				}
				n, readErr := response.Body.Read(buffer[:int(reserved)])
				remaining.Add(reserved - int64(n))
				hitLimit := false
				if n > 0 {
					stats.Lock()
					now := time.Now()
					if stats.first.IsZero() {
						stats.first = now
					}
					stats.sources[index] = true
					stats.total += int64(n)
					if stats.sampleStart.IsZero() {
						stats.warmup += int64(n)
						if stats.warmup >= warmupLimit || now.Sub(stats.first) >= 250*time.Millisecond {
							stats.sampleStart = now
						}
					} else {
						stats.measured += int64(n)
					}
					if stats.total >= options.DownloadBytes {
						stats.limitAt = now
						hitLimit = true
					}
					stats.Unlock()
				}
				if hitLimit {
					cancel()
					return
				}
				if readErr != nil {
					if readErr != io.EOF && ctx.Err() == nil {
						failures.Add(1)
					}
					return
				}
			}
		}(worker)
	}
	workers.Wait()
	finished := time.Now()
	stats.Lock()
	defer stats.Unlock()
	if !stats.limitAt.IsZero() {
		finished = stats.limitAt
	}
	details := DownloadDetails{Version: 2, Connections: streams, ActiveConnections: len(stats.sources), MeasuredBytes: stats.measured,
		WarmupBytes: stats.warmup, PartialFailure: failures.Load() > 0}
	if !stats.first.IsZero() {
		details.SetupMS = float64(stats.first.Sub(started).Microseconds()) / 1000
	}
	if !stats.sampleStart.IsZero() {
		details.SampleSeconds = max(0, finished.Sub(stats.sampleStart).Seconds())
	}
	elapsed := finished.Sub(started).Seconds()
	if elapsed > 0 {
		details.EndToEndMbps = float64(stats.total) * 8 / elapsed / 1e6
	}
	details.ShortSample = details.SampleSeconds < 1 || details.ActiveConnections < streams
	result := downloadResult{Bytes: stats.total, Details: details}
	if parent.Err() != nil {
		result.Error = "测试已暂停或取消"
		return result
	}
	if stats.total < 65536 {
		result.Error = "下载数据不足 64 KiB，可能是连接失败、测试地址异常或超时"
		return result
	}
	if stats.measured < 32<<10 || details.SampleSeconds < 0.1 {
		result.Error = "下载样本过短，请提高读取上限后重测"
		return result
	}
	if details.PartialFailure && streams == 1 {
		result.Error = "下载意外中断，未生成速度结果"
		return result
	}
	mbps := float64(stats.measured) * 8 / details.SampleSeconds / 1e6
	result.Mbps = &mbps
	return result
}
