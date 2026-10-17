package engine

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

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
		result.Error = "订阅超过 8 MiB 限制"
		return
	}
	input = strings.TrimSpace(strings.TrimPrefix(input, "\ufeff"))
	var document struct {
		Proxies []map[string]any `yaml:"proxies"`
	}
	err := yaml.Unmarshal([]byte(input), &document)
	mappings := document.Proxies
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
			result.Error = "订阅中没有可导入的节点；远程 proxy-providers 请先转换为完整订阅"
		}
		return
	}
	if len(mappings) > MaxNodes {
		result.Error = "单个订阅最多支持 2000 个节点"
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
	if len(result.Warnings) > 1 {
		result.Warnings = result.Warnings[:1]
	}
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

func FetchSubscription(raw string) SubscriptionResult {
	if err := validateHTTPS(raw); err != nil {
		return SubscriptionResult{Error: err.Error()}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	req.Header.Set("User-Agent", "NodeScope/1.0 Clash")
	client := &http.Client{Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		return validateHTTPS(req.URL.String())
	}}
	defer client.CloseIdleConnections()
	response, err := client.Do(req)
	if err != nil {
		return SubscriptionResult{Error: "订阅下载失败，请检查地址和网络"}
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return SubscriptionResult{Error: fmt.Sprintf("订阅服务器返回 HTTP %d", response.StatusCode)}
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, MaxSubscriptionBytes+1))
	if err != nil {
		return SubscriptionResult{Error: "订阅下载中断"}
	}
	if len(body) > MaxSubscriptionBytes {
		return SubscriptionResult{Error: "订阅超过 8 MiB 限制"}
	}
	return ParseSubscription(string(body))
}
