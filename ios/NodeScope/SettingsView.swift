import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var clearing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("筛选与网络") {
                    NavigationLink("地区、节点与 IP 排除") { ExclusionsView() }
                    LabeledContent("当前网络档案", value: model.activeNetworkName)
                    Text("在底部“网络”页建立与切换移动、电信等网络档案，各自保留历史和推荐。").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("允许后台续测", isOn: $model.preferences.continueInBackground)
                } header: { Text("后台测速") } footer: {
                    Text("iOS 26 及以上优先申请持续后台任务，系统会展示进度并允许取消；未获准时退回短时续测。旧系统使用短时后台时间。系统终止任务时取消当前节点、保存队列，回前台手动继续。不开启时进入后台即暂停。不保证完成全部节点，不会排队等待以后自动启动，也不会定时测速。")
                }
                Section {
                    Toggle("下载测速", isOn: $model.settings.downloadEnabled)
                    Toggle("下载测速仅限 Wi-Fi", isOn: $model.settings.wifiOnly)
                    Picker("下载连接数", selection: $model.settings.downloadConnections) {
                        Text("单连接 · 日常单路表现").tag(1)
                        Text("4 连接 · 多路吞吐").tag(4)
                    }
                    Picker("每节点读取上限", selection: $model.settings.downloadMiB) {
                        ForEach([2, 4, 8, 16, 32, 64, 128], id: \.self) { Text("\($0) MiB").tag($0) }
                    }
                    Picker("每节点时长上限", selection: $model.settings.downloadSeconds) {
                        ForEach([2, 4, 6, 8, 12], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                    Button("较长采样：64 MiB / 8 秒 / 4 连接") {
                        model.settings.downloadMiB = 64; model.settings.downloadSeconds = 8; model.settings.downloadConnections = 4
                    }
                } header: { Text("下载与流量") } footer: {
                    Text("开关与设置自动记忆，默认关闭，不自动增加原有流量上限。Mbps 是兆比特/秒，8 Mbps = 1 MB/s。新测量排除建连、首包和短预热，正文采样不足 1 秒时标记 ≈，不足 0.1 秒不报速度。高速节点需要更大读取量才能形成较长样本。多个连接共用每节点读取上限（含预热），不同节点仍串行。计时上限含建连；达到读取量或时间上限即结束。缓冲与协议开销会额外耗流量，上限不是运营商账单硬限额。")
                }
                Section {
                    Picker("采样轮次", selection: $model.settings.rounds) {
                        Text("快速 · 8 轮").tag(8)
                        Text("标准 · 16 轮").tag(16)
                        Text("深入 · 32 轮").tag(32)
                    }
                    Picker("超时时间", selection: $model.settings.timeoutSeconds) {
                        ForEach([3, 5, 8, 10], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                    Picker("采样间隔", selection: $model.settings.intervalMS) {
                        Text("0.7 秒").tag(700); Text("1.5 秒").tag(1500); Text("3 秒").tag(3000)
                    }
                    Picker("并行节点", selection: $model.settings.concurrency) {
                        ForEach([1, 2, 3, 4, 6], id: \.self) { Text("\($0) 个").tag($0) }
                    }.disabled(model.settings.downloadEnabled)
                } header: { Text("延迟采样") } footer: {
                    Text("延迟包含节点连接、TLS 和测试请求。失败率是请求失败比例，不是 ICMP 丢包率。开启下载时全部节点依次测试，避免下载占用带宽干扰其他节点延迟。建议隔一段时间重复测试。iOS 不保证持续后台运行，请尽量保持 App 在前台。")
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("延迟测试地址").font(.caption).foregroundStyle(.secondary)
                        TextField("HTTPS · 推荐返回 204", text: $model.settings.latencyURL, axis: .vertical)
                            .font(.subheadline).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下载测试地址").font(.caption).foregroundStyle(.secondary)
                        TextField("HTTPS · 大文件", text: $model.settings.downloadURL, axis: .vertical)
                            .font(.subheadline).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("测试目标") } footer: {
                    Text("默认使用 Google 204 和 Cloudflare 下载端点，会通过每个被测节点访问。服务可用性可能改变，可换为自己的地址。默认下载端点会按读取上限生成数据，不再固定返回 8 MiB。自定义地址保持原样，应能提供足够大的二进制文件。只接受 HTTPS，网页、压缩内容、重定向不视为有效下载。比较时应使用相同地址与连接数。")
                }
                Section {
                    Text("测速页可主动暂停，保留完成记录和剩余队列；继续时沿用原设置，未完成节点重新采样。“停止并放弃”会丢弃剩余队列。更换网络后需回到原网络档案再继续。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("暂停与继续") }
                Section("评分与推荐") {
                    NavigationLink("查看算法说明") { AlgorithmView() }
                }
                Section {
                    LabeledContent("已保留的下载读取量", value: ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .binary))
                    Button("清空测速记录", role: .destructive) { clearing = true }.disabled(model.running)
                } header: { Text("本机数据") } footer: {
                    Text("每节点、每网络档案保留最近 30 次记录，总上限 10,000 条。此处流量仅汇总已保留的完整测试记录，不是累计账单；取消、失败、订阅导入和协议开销可能未计入。订阅和凭据仅在本机加密保存。")
                }
                Section {
                    LabeledContent("版本", value: "1.2.0")
                    Link("项目源码与使用说明", destination: URL(string: "https://github.com/yiyiyiyayayu/speed-text")!)
                    NavigationLink("开源许可") { LicensesView() }
                }
            }
            .disabled(model.running)
            .navigationTitle("测速设置")
            .alert("清空全部测速记录？", isPresented: $clearing) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { model.clearHistory() }
            } message: { Text("订阅和测速设置将继续保留。") }
        }
    }
}

struct AlgorithmView: View {
    var body: some View {
        List {
            Section("先看稳定，再看快") {
                Text("每个节点多轮独立发起请求。统计延迟中位数、P95、失败率，以及通过 MAD 估计的稳健抖动。失败样本不参与延迟计算，直接降低评分。")
                Text("评分以延迟占 50%、P95 占 30%、抖动占 20% 为基础，再乘以成功率的三次方和样本置信修正。下载速度独立展示，不影响稳定性排名。")
            }
            Section("推荐哪一档") {
                Text("仅使用当前网络档案、相同测试地址、30 分钟内的结果。至少完成 6 轮、失败率不超过 10%。先排除自身 P95 超过中位延迟 2 倍或加 100 ms（取较大值）、抖动超过 30 ms 或中位延迟 35%（取较大值）的节点。再从稳定候选中选出分数距最高分不超过 8 分、P95 不高于最低中位延迟 1.6 倍或加 60 ms（取较大值）的档位。")
                Text("排序评分 = 本次评分 × 70% + 最近 24 小时最多 12 次同类历史评分均值 × 30%。本次全部失败时评分直接归零。")
            }
            Section("样本越多，结论越可靠") {
                Text("样本较少时显示「初步推荐」。至少 3 次测试、合计 24 个样本，且记录跨度不少于 10 分钟，才显示「推荐」。这是观测结果，不是未来稳定性的保证。")
                Text("可靠性置信下界使用 95% Wilson 区间。短时间内的样本可能相关，这一指标仅用于样本量修正，不能解释为长期在线率保证。")
                Text("系统自动识别 Wi-Fi / 蜂窝类型，具体 Wi-Fi 与运营商由你选择网络档案。不同档案的记录不参与同一推荐。系统无法确认同类型 Wi-Fi 切换或其他 VPN，请先确认档案再测速。")
            }
        }.navigationTitle("评分算法").navigationBarTitleDisplayMode(.inline)
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("NodeScope 使用 Mihomo v1.19.10（GPL-3.0）。本项目按 GPL-3.0 发布，并提供完整构建脚本。")
                Link("Mihomo 源码", destination: URL(string: "https://github.com/MetaCubeX/mihomo/tree/v1.19.10")!)
                Link("NodeScope 源码", destination: URL(string: "https://github.com/yiyiyiyayayu/speed-text")!)
                Text("各依赖保留各自版权与许可证。构建产物附有第三方许可证清单。")
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) {
                    Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }.padding(20)
        }.navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
    }
}
