package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
)

type Options struct {
	Rounds          int    `json:"rounds"`
	TimeoutSeconds  int    `json:"timeoutSeconds"`
	IntervalMS      int    `json:"intervalMS"`
	LatencyURL      string `json:"latencyURL"`
	DownloadURL     string `json:"downloadURL"`
	DownloadEnabled bool   `json:"downloadEnabled"`
	DownloadBytes   int64  `json:"downloadBytes"`
	DownloadSeconds int    `json:"downloadSeconds"`
}

type TestResult struct {
	Metrics         Metrics   `json:"metrics"`
	Samples         []float64 `json:"samples"`
	DownloadMbps    *float64  `json:"downloadMbps,omitempty"`
	DownloadedBytes int64     `json:"downloadedBytes"`
	DownloadError   string    `json:"downloadError,omitempty"`
	Error           string    `json:"error,omitempty"`
	Cancelled       bool      `json:"cancelled"`
}

type runContext struct {
	ctx    context.Context
	cancel context.CancelFunc
}

var runLock sync.Mutex
var runIDs atomic.Int64
var runs = map[int64]runContext{}
var downloadSlot = make(chan struct{}, 1)

func NewRun() int64 {
	id := runIDs.Add(1)
	ctx, cancel := context.WithCancel(context.Background())
	runLock.Lock()
	runs[id] = runContext{ctx, cancel}
	runLock.Unlock()
	return id
}
func CancelRun(id int64) {
	runLock.Lock()
	if r, ok := runs[id]; ok {
		r.cancel()
	}
	runLock.Unlock()
}
func EndRun(id int64) {
	runLock.Lock()
	if r, ok := runs[id]; ok {
		r.cancel()
		delete(runs, id)
	}
	runLock.Unlock()
}

func parseAdapter(config string) (C.Proxy, error) {
	var mapping map[string]any
	if err := json.Unmarshal([]byte(config), &mapping); err != nil {
		return nil, err
	}
	kind, _ := mapping["type"].(string)
	if !supported[kind] || mapping["dialer-proxy"] != nil {
		return nil, errors.New("unsupported node")
	}
	return adapter.ParseProxy(mapping)
}

func clientFor(proxy C.Proxy, timeout time.Duration) *http.Client {
	transport := &http.Transport{
		Proxy: nil, DisableKeepAlives: true, DisableCompression: true, ForceAttemptHTTP2: false,
		TLSHandshakeTimeout: timeout, ResponseHeaderTimeout: timeout,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, portText, err := net.SplitHostPort(address)
			if err != nil {
				return nil, err
			}
			port, err := strconv.ParseUint(portText, 10, 16)
			if err != nil {
				return nil, err
			}
			metadata := &C.Metadata{NetWork: C.TCP, Type: C.INNER, Host: host, DstPort: uint16(port)}
			if ip, err := netip.ParseAddr(host); err == nil {
				metadata.DstIP = ip
				metadata.Host = ""
			}
			// Every connection goes through this adapter. No direct fallback.
			return proxy.DialContext(ctx, metadata)
		},
	}
	return &http.Client{Transport: transport, Timeout: timeout, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
}

func TestNode(id int64, config string, options Options) (result TestResult) {
	result.Samples = []float64{}
	defer func() {
		if recover() != nil {
			result.Error = "节点协议初始化失败"
		}
	}()
	runLock.Lock()
	run, exists := runs[id]
	runLock.Unlock()
	if !exists {
		result.Error = "测试任务已结束"
		return
	}
	if options.Rounds < 3 || options.Rounds > 64 || options.TimeoutSeconds < 1 || options.TimeoutSeconds > 15 || options.IntervalMS < 0 || options.IntervalMS > 5000 {
		result.Error = "无效的测试参数"
		return
	}
	if err := validateHTTPS(options.LatencyURL); err != nil {
		result.Error = "延迟测试地址必须为 HTTPS"
		return
	}
	if options.DownloadEnabled {
		if validateHTTPS(options.DownloadURL) != nil || options.DownloadBytes < 65536 || options.DownloadBytes > 32<<20 || options.DownloadSeconds < 1 || options.DownloadSeconds > 10 {
			result.Error = "无效的下载测试参数"
			return
		}
	}
	proxy, err := parseAdapter(config)
	if err != nil {
		result.Error = "节点配置不受支持或不完整"
		return
	}
	defer proxy.Close()
	client := clientFor(proxy, time.Duration(options.TimeoutSeconds)*time.Second)
	defer client.CloseIdleConnections()
	for i := 0; i < options.Rounds; i++ {
		if run.ctx.Err() != nil {
			result.Cancelled = true
			break
		}
		probeCtx, cancel := context.WithTimeout(run.ctx, time.Duration(options.TimeoutSeconds)*time.Second)
		req, _ := http.NewRequestWithContext(probeCtx, http.MethodGet, options.LatencyURL, nil)
		req.Header.Set("Cache-Control", "no-cache, no-store")
		req.Header.Set("User-Agent", "NodeScope/1.0")
		start := time.Now()
		response, requestErr := client.Do(req)
		value := -1.0
		if requestErr == nil {
			// Include response completion for tiny endpoints, cap unexpected bodies.
			_, bodyErr := io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
			response.Body.Close()
			if bodyErr == nil && (response.StatusCode == 204 || response.StatusCode == 200) {
				value = float64(time.Since(start).Microseconds()) / 1000
			}
		}
		cancel()
		if run.ctx.Err() != nil {
			result.Cancelled = true
			break
		}
		result.Samples = append(result.Samples, value)
		if i < options.Rounds-1 {
			timer := time.NewTimer(time.Duration(options.IntervalMS) * time.Millisecond)
			select {
			case <-run.ctx.Done():
				timer.Stop()
				result.Cancelled = true
			case <-timer.C:
			}
		}
	}
	result.Metrics = Summarize(result.Samples)
	if !result.Cancelled && result.Metrics.Successes > 0 && options.DownloadEnabled {
		select {
		case downloadSlot <- struct{}{}:
			defer func() { <-downloadSlot }()
		case <-run.ctx.Done():
			result.Cancelled = true
			return
		}
		// Serialize downloads to avoid bandwidth competition. Fresh transport and
		// connection include setup cost, a conservative end-to-end throughput.
		result.DownloadMbps, result.DownloadedBytes, result.DownloadError = download(run.ctx, proxy, options)
		if run.ctx.Err() != nil {
			result.Cancelled = true
		}
	}
	return
}

func download(parent context.Context, proxy C.Proxy, options Options) (*float64, int64, string) {
	ctx, cancel := context.WithTimeout(parent, time.Duration(options.DownloadSeconds)*time.Second)
	defer cancel()
	client := clientFor(proxy, time.Duration(options.DownloadSeconds)*time.Second)
	defer client.CloseIdleConnections()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, options.DownloadURL, nil)
	req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", options.DownloadBytes-1))
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Set("Cache-Control", "no-cache, no-store")
	start := time.Now()
	response, err := client.Do(req)
	if err != nil {
		return nil, 0, "下载连接失败或超时"
	}
	defer response.Body.Close()
	if response.StatusCode != 200 && response.StatusCode != 206 {
		return nil, 0, fmt.Sprintf("下载返回 HTTP %d", response.StatusCode)
	}
	if encoding := response.Header.Get("Content-Encoding"); encoding != "" && encoding != "identity" {
		return nil, 0, "下载服务器返回压缩内容"
	}
	n, readErr := io.Copy(io.Discard, io.LimitReader(response.Body, options.DownloadBytes))
	if n < 65536 {
		return nil, n, "下载数据不足 64 KiB"
	}
	if readErr != nil && ctx.Err() == nil {
		return nil, n, "下载中断"
	}
	if parent.Err() != nil {
		return nil, n, "测试已取消"
	}
	mbps := float64(n) * 8 / time.Since(start).Seconds() / 1e6
	return &mbps, n, ""
}
