NodeScope（节点测速）首个版本，适用于 iOS 16 及以上的 iPhone / iPad。

已通过核心测试、竞态与静态检查、iOS arm64 构建，以及模拟器订阅导入、加密保存、重启恢复和下载开关记忆测试。[构建记录](https://github.com/yiyiyiyayayu/speed-text/actions/runs/38999525204) · [界面测试](https://github.com/yiyiyiyayayu/speed-text/actions/runs/38999525301)。

- 订阅分组，支持 Clash YAML 与常见分享链接订阅。
- 多轮延迟、P95、失败率、抖动与历史记录。
- 稳定性优先的评分与推荐档位，支持多种排序。
- 可选下载测速，默认关闭、自动记忆，提供 Wi-Fi 限制和读取上限。
- 本机加密保存订阅凭据，支持不含凭据的 CSV 导出。

安装：下载下方 `NodeScope-unsigned.ipa` → 导入全能签 / ESign → 使用自己的有效证书与描述文件签名 → 安装。未签名 IPA 不能直接安装。

默认下载上限为每节点读取 8 MiB 或 4 秒，实际网络流量还包含协议、握手和系统缓冲开销。先关闭下载测试延迟，再按需要测试候选节点。

构建和使用说明：[README](https://github.com/yiyiyiyayayu/speed-text#readme)。算法细节：[评分算法](https://github.com/yiyiyiyayayu/speed-text/blob/main/docs/ALGORITHM.md)。
