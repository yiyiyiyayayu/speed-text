package engine

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/common/convert"
	"github.com/metacubex/mihomo/log"
	"gopkg.in/yaml.v3"
)

const MaxSubscriptionBytes = 8 << 20
const MaxNodes = 2000

type Node struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Kind   string `json:"kind"`
	Server string `json:"server"`
	Port   int    `json:"port"`
	Config string `json:"config"`
}

type SubscriptionResult struct {
	Nodes    []Node   `json:"nodes"`
	Skipped  int      `json:"skipped"`
	Warnings []string `json:"warnings"`
	Error    string   `json:"error,omitempty"`
}

var supported = map[string]bool{"ss": true, "ssr": true, "vmess": true, "vless": true, "trojan": true, "hysteria": true, "hysteria2": true, "tuic": true, "socks5": true, "http": true, "anytls": true, "snell": true}

func init() { log.SetLevel(log.SILENT) }

// Only proxy definitions are consumed. Rules, providers, scripts, routing and
// external files from a subscription are never executed or fetched.
func ParseSubscription(input string) (result SubscriptionResult) {
	result.Nodes = []Node{}
	result.Warnings = []string{}
	defer func() {
		if recover() != nil {
			result.Error = "订阅格式无法解析"
		}
	}()
	if len(input) > MaxSubscriptionBytes {
		result.Error = subscriptionTooLargeMessage
		return
	}
	input = strings.TrimSpace(strings.TrimPrefix(input, "\ufeff"))
	if input == "" { result.Error = "订阅返回空内容，请检查订阅链接或稍后重试"; return }
	lower := strings.ToLower(input)
	if strings.HasPrefix(lower, "<!doctype html") || strings.HasPrefix(lower, "<html") {
		result.Error = "订阅服务器返回了网页，请检查是否为订阅链接或需要登录验证"; return
	}
	var document subscriptionDocument
	err := yaml.Unmarshal([]byte(input), &document)
	mappings := document.Proxies
	for _, name := range providerNames(document.Providers) {
		provider := document.Providers[name]
		if provider.Type == "inline" { mappings = append(mappings, provider.Payload...) }
	}
	if len(mappings) == 0 && len(document.Providers) > 0 {
		result.Error = "此配置引用远程节点源，请通过订阅地址导入以加载完整节点"
		return
	}
	if len(document.Providers) > 0 {
		for _, provider := range document.Providers {
			if provider.Type != "inline" { result.Warnings = append(result.Warnings, remoteSourcesNotLoadedWarning); break }
		}
	}
	if len(mappings) == 0 {
		mappings, _ = convert.ConvertsV2Ray([]byte(input))
		// Converter intentionally ignores unknown URI lines. Report them.
		for _, line := range strings.Split(string(convert.DecodeBase64([]byte(input))), "\n") {
			line = strings.TrimSpace(line)
			if strings.Contains(line, "://") {
				scheme := strings.ToLower(strings.SplitN(line, "://", 2)[0])
				if !supported[scheme] && scheme != "hy2" {
					result.Skipped++
				}
			}
		}
	}
	if len(mappings) == 0 {
		if err != nil {
			result.Error = "无法识别订阅，请使用 Clash YAML 或分享链接订阅"
		} else {
			result.Error = "订阅返回的内容中没有节点，请确认使用了正确的订阅地址与格式"
		}
		return
	}
	if len(mappings) > MaxNodes {
		result.Error = tooManyNodesMessage
		return
	}
	seen := map[string]bool{}
	for _, config := range mappings {
		kind, _ := config["type"].(string)
		server, _ := config["server"].(string)
		port, _ := strconv.Atoi(fmt.Sprint(config["port"]))
		if !supported[kind] || server == "" || port < 1 || port > 65535 {
			result.Skipped++
			continue
		}
		// Chained dialers and file-backed certificates need external state.
		if config["dialer-proxy"] != nil || config["certificate"] != nil || config["private-key"] != nil {
			result.Skipped++
			continue
		}
		name, _ := config["name"].(string)
		if name == "" {
			name = server
		}
		delete(config, "name")
		canonical, marshalErr := json.Marshal(config)
		if marshalErr != nil {
			result.Skipped++
			continue
		}
		digest := sha256.Sum256(canonical)
		id := hex.EncodeToString(digest[:16])
		if seen[id] {
			continue
		}
		seen[id] = true
		config["name"] = name
		encoded, _ := json.Marshal(config)
		result.Nodes = append(result.Nodes, Node{ID: id, Name: name, Kind: kind, Server: server, Port: port, Config: string(encoded)})
		if skip, _ := config["skip-cert-verify"].(bool); skip {
			result.Warnings = append(result.Warnings, "部分节点配置关闭了节点服务器证书验证")
		}
	}
	result.Warnings = uniqueStrings(result.Warnings)
	if len(result.Nodes) == 0 {
		result.Error = "没有受支持的节点，请检查订阅格式"
	}
	return
}

func validateHTTPS(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return errors.New("请使用有效的 HTTPS 地址")
	}
	return nil
}

