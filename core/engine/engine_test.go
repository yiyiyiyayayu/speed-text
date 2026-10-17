package engine

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestSubscriptionFormatsAndIsolation(t *testing.T) {
	yaml := `proxies:
  - {name: 香港 A, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: test}
  - {name: 重复别名, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: test}
  - {name: 不允许直连, type: direct}
  - {name: 链式节点, type: socks5, server: localhost, port: 1234, dialer-proxy: other}
proxy-providers:
  remote: {type: http, url: 'https://should-never-be-fetched.invalid'}
`
	parsed := ParseSubscription(yaml)
	if parsed.Error != "" || len(parsed.Nodes) != 1 || parsed.Skipped != 2 {
		t.Fatalf("unexpected import: %+v", parsed)
	}
	renamed := ParseSubscription(strings.ReplaceAll(yaml, "香港 A", "新名字"))
	if parsed.Nodes[0].ID != renamed.Nodes[0].ID {
		t.Fatal("rename broke stable identity")
	}
	link := "trojan://secret@example.com:443?sni=example.com#Test"
	for _, input := range []string{link, base64.StdEncoding.EncodeToString([]byte(link))} {
		p := ParseSubscription(input)
		if p.Error != "" || len(p.Nodes) != 1 || p.Nodes[0].Kind != "trojan" {
			t.Fatalf("link import failed: %+v", p)
		}
	}
	for _, input := range []string{"hello", strings.Repeat("a", MaxSubscriptionBytes+1), "proxy-providers: {}"} {
		if ParseSubscription(input).Error == "" {
			t.Fatal("accepted invalid subscription")
		}
	}
}

func TestScorePenalizesInstabilityAndSmallSamples(t *testing.T) {
	stable := Summarize([]float64{100, 102, 98, 101, 99, 100, 100, 101})
	flaky := Summarize([]float64{50, 52, -1, 49, 50, -1, 51, 50})
	tail := Summarize([]float64{100, 102, 98, 101, 99, 100, 100, 1800})
	if stable.Score <= flaky.Score || stable.Score <= tail.Score {
		t.Fatalf("unstable nodes outranked stable: %+v %+v %+v", stable, flaky, tail)
	}
	if Summarize([]float64{100}).Score >= Summarize([]float64{100, 100, 100, 100, 100, 100, 100, 100}).Score {
		t.Fatal("missing sample confidence penalty")
	}
	failed := Summarize([]float64{-1, -1, -1})
	if failed.Score != 0 || failed.MedianMS != 0 || failed.FailureRate != 1 {
		t.Fatal("failed probes became fast successes")
	}
	if stable.JitterMS <= 0 || stable.P95MS < stable.MedianMS {
		t.Fatal("bad summary statistics")
	}
}

// A real CONNECT server lets the test observe the data path, not just the
// adapter configuration. The test fails if the HTTP client bypasses the node.
func connectProxy(t *testing.T, count *atomic.Int64) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "CONNECT" {
			http.Error(w, "CONNECT required", 400)
			return
		}
		count.Add(1)
		upstream, err := net.DialTimeout("tcp", r.Host, time.Second)
		if err != nil {
			http.Error(w, "unavailable", 502)
			return
		}
		conn, buffer, err := w.(http.Hijacker).Hijack()
		if err != nil {
			upstream.Close()
			return
		}
		_, _ = buffer.WriteString("HTTP/1.1 200 Connection established\r\n\r\n")
		_ = buffer.Flush()
		go func() { defer conn.Close(); defer upstream.Close(); _, _ = io.Copy(upstream, buffer) }()
		go func() { defer conn.Close(); defer upstream.Close(); _, _ = io.Copy(conn, upstream) }()
	}))
}

func proxyConfig(address string) string {
	host, port, _ := net.SplitHostPort(address)
	return fmt.Sprintf(`{"name":"integration","type":"http","server":%q,"port":%s}`, host, port)
}

func TestTrafficUsesProxyAndNeverFallsBack(t *testing.T) {
	var count atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("through-node")) }))
	defer server.Close()
	proxyServer := connectProxy(t, &count)
	defer proxyServer.Close()
	proxy, err := parseAdapter(proxyConfig(proxyServer.Listener.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	client := clientFor(proxy, 2*time.Second)
	defer client.CloseIdleConnections()
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if string(body) != "through-node" || count.Load() != 1 {
		t.Fatal("request bypassed node")
	}
	// Reserve a real address then close it; the target remains reachable.
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := closed.Addr().String()
	closed.Close()
	bad, err := parseAdapter(proxyConfig(address))
	if err != nil {
		t.Fatal(err)
	}
	defer bad.Close()
	broken := clientFor(bad, time.Second)
	defer broken.CloseIdleConnections()
	if response, err := broken.Get(server.URL); err == nil {
		response.Body.Close()
		t.Fatal("unreachable node fell back to direct access")
	}
}

func TestCancelAndTLSFailures(t *testing.T) {
	var count atomic.Int64
	proxyServer := connectProxy(t, &count)
	defer proxyServer.Close()
	// A self-signed target must fail: the test endpoint's TLS check cannot be
	// disabled by a node's own skip-cert-verify option.
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer target.Close()
	id := NewRun()
	defer EndRun(id)
	options := Options{Rounds: 3, TimeoutSeconds: 1, LatencyURL: target.URL}
	result := TestNode(id, proxyConfig(proxyServer.Listener.Addr().String()), options)
	if result.Metrics.Successes != 0 || result.Metrics.Attempts != 3 || count.Load() != 3 {
		t.Fatalf("TLS failure misclassified: %+v (%d)", result, count.Load())
	}
	CancelRun(id)
	result = TestNode(id, proxyConfig(proxyServer.Listener.Addr().String()), options)
	if !result.Cancelled || len(result.Samples) != 0 {
		t.Fatal("canceled run produced measurement")
	}
}

func TestDownloadReadLimitAndHTTPFailures(t *testing.T) {
	var count atomic.Int64
	proxyServer := connectProxy(t, &count)
	defer proxyServer.Close()
	proxy, err := parseAdapter(proxyConfig(proxyServer.Listener.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/error" {
			http.Error(w, "no", 503)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		// Intentionally ignores Range, as many servers do.
		_, _ = io.WriteString(w, strings.Repeat("x", 1<<20))
	}))
	defer server.Close()
	opts := Options{DownloadURL: server.URL, DownloadBytes: 128 << 10, DownloadSeconds: 2}
	speed, n, message := download(context.Background(), proxy, opts)
	if speed == nil || *speed <= 0 || n != 128<<10 || message != "" {
		t.Fatalf("download limit failed: %v %d %s", speed, n, message)
	}
	opts.DownloadURL = server.URL + "/error"
	if speed, _, message := download(context.Background(), proxy, opts); speed != nil || message == "" {
		t.Fatal("HTTP error became speed result")
	}
}

func TestMalformedConfigAndInvalidOptions(t *testing.T) {
	id := NewRun()
	defer EndRun(id)
	result := TestNode(id, `{"type":"direct"}`, Options{Rounds: 3, TimeoutSeconds: 1, LatencyURL: "https://example.com"})
	if result.Error == "" {
		t.Fatal("accepted direct adapter")
	}
	result = TestNode(id, "{}", Options{Rounds: 999})
	encoded, err := json.Marshal(result)
	if err != nil || !strings.Contains(string(encoded), "error") {
		t.Fatal("invalid error response")
	}
}
