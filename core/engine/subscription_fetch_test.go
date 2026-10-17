package engine

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

const providerNodeFixture = `proxies:
  - {name: provider node, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: fixture}
`

func TestFetchRemoteProvidersAndDeduplicate(t *testing.T) {
	var sourceHits atomic.Int64
	var wrongAgent atomic.Bool
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.UserAgent() != subscriptionUserAgent { wrongAgent.Store(true) }
		switch r.URL.Path {
		case "/root":
			fmt.Fprint(w, `proxies:
  - {name: direct node, type: trojan, server: example.org, port: 443, password: fixture}
proxy-providers:
  a: {type: http, url: './nodes?token=fixture-secret'}
  b: {type: http, url: './nodes?token=fixture-secret'}
`)
		case "/remote-only":
			fmt.Fprint(w, "proxy-providers:\n  a: {type: http, url: /nodes}\n")
		case "/nested":
			fmt.Fprint(w, "proxy-providers:\n  a: {type: http, url: /remote-only}\n")
		case "/nodes":
			sourceHits.Add(1)
			fmt.Fprint(w, providerNodeFixture)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	result := fetchSubscriptionWithClient(context.Background(), server.URL+"/root", server.Client())
	if result.Error != "" || len(result.Nodes) != 2 || sourceHits.Load() != 1 {
		t.Fatalf("remote import or source cache failed: count=%d hits=%d error=%s", len(result.Nodes), sourceHits.Load(), result.Error)
	}
	if len(result.Warnings) != 0 || wrongAgent.Load() { t.Fatal("loaded sources retained paste warning or wrong user agent") }
	for _, path := range []string{"/remote-only", "/nested"} {
		result = fetchSubscriptionWithClient(context.Background(), server.URL+path, server.Client())
		if result.Error != "" || len(result.Nodes) != 1 { t.Fatalf("provider-only or nested import failed: %s", result.Error) }
	}
}

func TestRemoteSourceFailuresAreAtomicAndPrivate(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/root":
			fmt.Fprint(w, providerNodeFixture+"\nproxy-providers:\n  bad: {type: http, url: '/missing?token=fixture-secret'}\n")
		case "/cycle":
			fmt.Fprint(w, "proxy-providers:\n  a: {type: http, url: /cycle}\n")
		case "/one":
			fmt.Fprint(w, "proxy-providers:\n  a: {type: http, url: /two}\n")
		case "/two":
			fmt.Fprint(w, "proxy-providers:\n  a: {type: http, url: /three}\n")
		case "/three":
			fmt.Fprint(w, "proxy-providers:\n  a: {type: http, url: /four}\n")
		case "/four":
			fmt.Fprint(w, providerNodeFixture)
		case "/file":
			fmt.Fprint(w, "proxy-providers:\n  a: {type: file, path: ./local.yaml}\n")
		default:
			http.Error(w, "fixture-secret", http.StatusForbidden)
		}
	}))
	defer server.Close()
	for _, path := range []string{"/root", "/cycle", "/one", "/file"} {
		result := fetchSubscriptionWithClient(context.Background(), server.URL+path, server.Client())
		if result.Error == "" || len(result.Nodes) != 0 { t.Fatalf("partial import accepted for %s", path) }
		if strings.Contains(result.Error, "fixture-secret") || strings.Contains(result.Error, server.URL) { t.Fatal("subscription credential or URL leaked into error") }
	}
}

func TestRemoteSourcesRejectHTTPSDowngrade(t *testing.T) {
	var insecureHits atomic.Int64
	insecure := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { insecureHits.Add(1) }))
	defer insecure.Close()
	secure := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" { http.Redirect(w, r, insecure.URL, http.StatusFound); return }
		fmt.Fprintf(w, "proxy-providers:\n  a: {type: http, url: '%s'}\n", insecure.URL)
	}))
	defer secure.Close()
	for _, path := range []string{"/root", "/redirect"} {
		result := fetchSubscriptionWithClient(context.Background(), secure.URL+path, secure.Client())
		if result.Error == "" { t.Fatal("accepted insecure source or redirect") }
	}
	if insecureHits.Load() != 0 { t.Fatal("sent a request to an insecure source") }
}

func TestRemoteSourceCountAndAggregateSizeLimits(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/many":
			fmt.Fprint(w, "proxy-providers:\n")
			for i := 0; i < 9; i++ { fmt.Fprintf(w, "  p%d: {type: http, url: '/nodes?id=%d'}\n", i, i) }
		case "/large-root":
			fmt.Fprint(w, "proxy-providers:\n  a: {type: http, url: /large-body}\n")
		case "/large-body":
			fmt.Fprint(w, strings.Repeat("a", MaxSubscriptionBytes))
		default:
			fmt.Fprint(w, providerNodeFixture)
		}
	}))
	defer server.Close()
	for _, path := range []string{"/many", "/large-root"} {
		result := fetchSubscriptionWithClient(context.Background(), server.URL+path, server.Client())
		if result.Error == "" || len(result.Nodes) != 0 { t.Fatalf("missing source limit for %s", path) }
	}
}

func TestInlineProvidersAndAccurateNoNodeErrors(t *testing.T) {
	inline := ParseSubscription(`proxy-providers:
  local:
    type: inline
    payload:
      - {name: inline, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: fixture}
`)
	if inline.Error != "" || len(inline.Nodes) != 1 { t.Fatal("inline provider was not imported") }
	remote := ParseSubscription("proxy-providers:\n  a: {type: http, url: 'https://example.invalid/private'}\n")
	if !strings.Contains(remote.Error, "远程节点源") { t.Fatal("missing provider-specific paste guidance") }
	for _, input := range []string{"", "{}", `{"message":"fixture-secret","status":false}`, "<!doctype html><html>login</html>"} {
		result := ParseSubscription(input)
		if result.Error == "" || strings.Contains(result.Error, "远程") || strings.Contains(result.Error, "fixture-secret") {
			t.Fatal("empty, API and HTML responses were incorrectly classified as remote providers")
		}
	}
}

func TestSubscriptionTLSAndCancellation(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, providerNodeFixture) }))
	defer server.Close()
	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	result := fetchSubscriptionWithClient(context.Background(), server.URL+"/fixture-secret", &http.Client{Transport: transport})
	if !strings.Contains(result.Error, "证书") || strings.Contains(result.Error, "fixture-secret") { t.Fatal("TLS error was not classified safely") }
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result = fetchSubscriptionWithClient(ctx, server.URL, server.Client())
	if !strings.Contains(result.Error, "取消") { t.Fatal("cancellation was not preserved") }
}
