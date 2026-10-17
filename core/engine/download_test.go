package engine

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDownloadPayloadTimingExcludesSetup(t *testing.T) {
	var count atomic.Int64
	relay := connectProxy(t, &count)
	defer relay.Close()
	proxy, err := parseAdapter(proxyConfig(relay.Listener.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(350 * time.Millisecond)
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		for i := 0; i < 128; i++ {
			if _, err := w.Write([]byte(strings.Repeat("x", 8<<10))); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			time.Sleep(5 * time.Millisecond)
		}
	}))
	defer target.Close()
	got := download(context.Background(), proxy, Options{DownloadURL: target.URL, DownloadBytes: 1 << 20, DownloadSeconds: 3})
	if got.Mbps == nil || got.Error != "" || got.Details.SetupMS < 300 || got.Details.WarmupBytes == 0 || got.Details.MeasuredBytes+got.Details.WarmupBytes != got.Bytes {
		t.Fatalf("bad measurement: %+v", got)
	}
	if *got.Mbps <= got.Details.EndToEndMbps*1.15 || *got.Mbps < 5 || *got.Mbps > 25 {
		t.Fatalf("setup biases payload rate: %+v, speed %v", got, *got.Mbps)
	}
	if count.Load() != 1 {
		t.Fatal("download bypassed node")
	}
}

func TestDownloadParallelStreamsShareBudget(t *testing.T) {
	var count, active, peak atomic.Int64
	relay := connectProxy(t, &count)
	defer relay.Close()
	proxy, err := parseAdapter(proxyConfig(relay.Listener.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := active.Add(1)
		defer active.Add(-1)
		for old := peak.Load(); n > old && !peak.CompareAndSwap(old, n); old = peak.Load() {
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		for i := 0; i < 512; i++ {
			if _, err := w.Write([]byte(strings.Repeat("x", 16<<10))); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			time.Sleep(5 * time.Millisecond)
		}
	}))
	defer target.Close()
	got := download(context.Background(), proxy, Options{DownloadURL: target.URL, DownloadBytes: 4 << 20, DownloadSeconds: 3, DownloadConnections: 4})
	if got.Bytes != 4<<20 || got.Details.MeasuredBytes+got.Details.WarmupBytes != 4<<20 || peak.Load() < 2 || count.Load() != 4 || got.Details.ActiveConnections != 4 {
		t.Fatalf("shared cap/parallelism failed: %+v, peak %d, conns %d", got, peak.Load(), count.Load())
	}
	if got.Mbps == nil || !got.Details.ShortSample {
		t.Fatalf("brief sample must be approximate: %+v", got)
	}
}

func TestDownloadStallRemainsInSamplingTimeAndCancelIsNotSpeed(t *testing.T) {
	var count atomic.Int64
	relay := connectProxy(t, &count)
	defer relay.Close()
	proxy, err := parseAdapter(proxyConfig(relay.Listener.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		for i := 0; i < 16; i++ {
			if _, err := w.Write([]byte(strings.Repeat("x", 32<<10))); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			time.Sleep(5 * time.Millisecond)
		}
		<-r.Context().Done()
	}))
	defer target.Close()
	opts := Options{DownloadURL: target.URL, DownloadBytes: 8 << 20, DownloadSeconds: 1}
	got := download(context.Background(), proxy, opts)
	if got.Mbps == nil || got.Details.SampleSeconds < 0.8 || *got.Mbps > 4 {
		t.Fatalf("stall hidden from average: %+v", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	got = download(ctx, proxy, opts)
	if got.Mbps != nil || got.Error == "" {
		t.Fatalf("cancellation produced a speed: %+v", got)
	}
}

func TestDownloadRejectsFalsePayloadsAndHandlesTinySamples(t *testing.T) {
	var count atomic.Int64
	relay := connectProxy(t, &count)
	defer relay.Close()
	proxy, err := parseAdapter(proxyConfig(relay.Listener.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/html" {
			w.Header().Set("Content-Type", "text/html")
		} else {
			w.Header().Set("Content-Type", "application/octet-stream")
		}
		_, _ = w.Write([]byte(strings.Repeat("x", 64<<10)))
	}))
	defer target.Close()
	for _, path := range []string{"/html", "/tiny"} {
		got := download(context.Background(), proxy, Options{DownloadURL: target.URL + path, DownloadBytes: 2 << 20, DownloadSeconds: 2})
		if got.Mbps != nil || got.Error == "" {
			t.Fatalf("false precision for %s: %+v", path, got)
		}
	}
}

func TestDefaultDownloadGeneratorHonorsSelectedBudgetAndCustomURLsStayIntact(t *testing.T) {
	u, err := url.Parse(downloadTarget("https://speed.cloudflare.com/__down?bytes=8388608", 64<<20))
	if err != nil {
		t.Fatal(err)
	}
	if u.Query().Get("bytes") != "67108864" || u.Query().Get("_nodescope") == "" {
		t.Fatal("fixed generator not repaired")
	}
	custom := "https://example.com/file?signature=preserve&bytes=123"
	if downloadTarget(custom, 64<<20) != custom {
		t.Fatal("custom signed URL altered")
	}
}
