package engine

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	maxProviderDepth = 2
	maxRemoteSources = 8
	subscriptionTooLargeMessage = "订阅及节点源总大小超过 8 MiB 限制"
	tooManyNodesMessage = "单个订阅最多支持 2000 个节点"
	remoteSourcesNotLoadedWarning = "粘贴配置仅导入内嵌节点；通过订阅地址导入可加载远程节点源"
	subscriptionUserAgent = "ClashMeta/v1.19.10"
)

type providerReference struct {
	Type string `yaml:"type"`
	URL string `yaml:"url"`
	Payload []map[string]any `yaml:"payload"`
}

type subscriptionDocument struct {
	Proxies []map[string]any `yaml:"proxies"`
	Providers map[string]providerReference `yaml:"proxy-providers"`
}

func providerNames(providers map[string]providerReference) []string {
	names := make([]string, 0, len(providers))
	for name := range providers { names = append(names, name) }
	sort.Strings(names)
	return names
}

func uniqueStrings(values []string) []string {
	result := []string{}
	seen := map[string]bool{}
	for _, value := range values {
		if !seen[value] { result = append(result, value); seen[value] = true }
	}
	return result
}

func FetchSubscription(raw string) SubscriptionResult {
	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	return fetchSubscriptionWithClient(context.Background(), raw, &http.Client{Transport: transport})
}

func fetchSubscriptionWithClient(parent context.Context, raw string, original *http.Client) SubscriptionResult {
	if err := validateHTTPS(raw); err != nil { return SubscriptionResult{Error: err.Error()} }
	ctx, cancel := context.WithTimeout(parent, 25*time.Second)
	defer cancel()
	client := *original
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 { return errors.New("too many redirects") }
		return validateHTTPS(req.URL.String())
	}
	loader := &subscriptionLoader{
		ctx: ctx, client: &client, active: map[string]bool{},
		cache: map[string]SubscriptionResult{}, remaining: MaxSubscriptionBytes,
	}
	return loader.load(raw, 0)
}

type subscriptionLoader struct {
	ctx context.Context
	client *http.Client
	active map[string]bool
	cache map[string]SubscriptionResult
	requests int
	remaining int
}

func (loader *subscriptionLoader) load(raw string, depth int) SubscriptionResult {
	if depth > maxProviderDepth { return SubscriptionResult{Error: "远程节点源嵌套超过两层限制"} }
	if loader.active[raw] { return SubscriptionResult{Error: "远程节点源存在循环引用"} }
	if cached, exists := loader.cache[raw]; exists { return cached }
	// The root plus at most eight distinct remote sources.
	if loader.requests >= maxRemoteSources+1 { return SubscriptionResult{Error: "远程节点源数量超过 8 个限制"} }
	if validateHTTPS(raw) != nil { return SubscriptionResult{Error: "远程节点源必须使用有效的 HTTPS 地址"} }
	loader.requests++
	loader.active[raw] = true
	defer delete(loader.active, raw)

	body, finalURL, message := loader.download(raw)
	if message != "" { return SubscriptionResult{Error: message} }
	parsed := ParseSubscription(string(body))
	var document subscriptionDocument
	err := yaml.Unmarshal(body, &document)
	if len(document.Providers) == 0 {
		loader.cache[raw] = parsed
		return parsed
	}
	if err != nil { return SubscriptionResult{Error: "远程节点源配置格式错误"} }
	if parsed.Error == subscriptionTooLargeMessage || parsed.Error == tooManyNodesMessage || parsed.Error == "订阅格式无法解析" { return parsed }
	parsed.Error = ""
	cleanWarnings := []string{}
	for _, warning := range parsed.Warnings {
		if warning != remoteSourcesNotLoadedWarning { cleanWarnings = append(cleanWarnings, warning) }
	}
	parsed.Warnings = cleanWarnings
	for _, name := range providerNames(document.Providers) {
		provider := document.Providers[name]
		if provider.Type == "inline" { continue } // Already parsed without network access.
		if provider.Type != "" && provider.Type != "http" {
			return SubscriptionResult{Error: "订阅包含无法在手机中加载的本机文件或不支持的节点源"}
		}
		reference, err := url.Parse(provider.URL)
		if err != nil || provider.URL == "" { return SubscriptionResult{Error: "远程节点源缺少有效的 HTTPS 地址"} }
		target := finalURL.ResolveReference(reference)
		// Fragments are not sent in HTTP requests and must not bypass cycle detection.
		target.Fragment = ""
		nested := loader.load(target.String(), depth+1)
		if nested.Error != "" {
			return SubscriptionResult{Error: "远程节点源获取失败：" + nested.Error}
		}
		parsed.Nodes = append(parsed.Nodes, nested.Nodes...)
		parsed.Skipped += nested.Skipped
		parsed.Warnings = append(parsed.Warnings, nested.Warnings...)
	}
	nodes := []Node{}
	seen := map[string]bool{}
	for _, node := range parsed.Nodes {
		if !seen[node.ID] { nodes = append(nodes, node); seen[node.ID] = true }
	}
	if len(nodes) > MaxNodes { return SubscriptionResult{Error: tooManyNodesMessage} }
	parsed.Nodes = nodes
	parsed.Warnings = uniqueStrings(parsed.Warnings)
	if len(nodes) == 0 { parsed.Error = "订阅及远程节点源中没有可导入的节点" }
	loader.cache[raw] = parsed
	return parsed
}

func (loader *subscriptionLoader) download(raw string) ([]byte, *url.URL, string) {
	req, err := http.NewRequestWithContext(loader.ctx, http.MethodGet, raw, nil)
	if err != nil { return nil, nil, "订阅地址无效" }
	req.Header.Set("User-Agent", subscriptionUserAgent)
	req.Header.Set("Accept", "application/yaml, text/yaml, text/plain, application/json, */*")
	response, err := loader.client.Do(req)
	if err != nil { return nil, nil, subscriptionNetworkMessage(err) }
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, nil, httpStatusMessage(response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, int64(loader.remaining)+1))
	if err != nil { return nil, nil, subscriptionNetworkMessage(err) }
	if len(body) > loader.remaining { return nil, nil, subscriptionTooLargeMessage }
	loader.remaining -= len(body)
	return body, response.Request.URL, ""
}

func subscriptionNetworkMessage(err error) string {
	if errors.Is(err, context.DeadlineExceeded) { return "订阅请求超时，请稍后重试或更换网络" }
	if errors.Is(err, context.Canceled) { return "订阅请求已取消" }
	var certificateError *tls.CertificateVerificationError
	if errors.As(err, &certificateError) { return "订阅服务器证书验证失败" }
	var dnsError *net.DNSError
	if errors.As(err, &dnsError) { return "订阅域名解析失败，请检查地址或更换网络" }
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() { return "订阅请求超时，请稍后重试或更换网络" }
	// Never include url.Error.Error(): it can contain the subscription credential.
	return "订阅下载失败，请检查地址和网络"
}

func httpStatusMessage(status int) string {
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		return "订阅服务器拒绝访问（HTTP " + strconv.Itoa(status) + "），请检查订阅权限或客户端限制"
	}
	return "订阅服务器返回 HTTP " + strconv.Itoa(status)
}

