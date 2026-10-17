import Charts
import SwiftUI

struct NodesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var detail: RankedNode?
    @State private var exportURL: URL?
    @State private var showExport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    overview
                    networkPicker
                    groupPicker
                    controls
                    let rows = model.ranked()
                    if rows.isEmpty { emptyState }
                    else {
                        ForEach(rows) { row in
                            Button { detail = row } label: { NodeCard(row: row, testing: model.pending.contains(row.id), excluded: model.preferences.excludes(row.entry)) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { detail = row } label: { Label("查看详情", systemImage: "info.circle") }
                                    Button { model.excludeNode(row.entry) } label: { Label("排除此节点", systemImage: "minus.circle") }.disabled(model.running)
                                    Button { model.excludeServer(row.entry) } label: { Label("排除此服务器", systemImage: "network") }.disabled(model.running)
                                }
                        }
                    }
                    Text("结果来自本机当前网络。同一节点会随时间、测试地址和网络变化；多次测试更有参考价值。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Theme.background)
            .navigationTitle("节点测速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 5) {
                        Circle().fill(model.online ? Theme.accent : .orange).frame(width: 6, height: 6)
                        Text(model.activeNetworkName).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { exportURL = model.exportCSV(); showExport = exportURL != nil } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(model.vault.measurements.isEmpty)
                    Button { adding = true } label: { Image(systemName: "plus") }.disabled(model.running || model.importing)
                        .accessibilityIdentifier("addSubscription")
                }
            }
            .safeAreaInset(edge: .bottom) { testBar }
            .sheet(isPresented: $adding) { AddSubscriptionView() }
            .sheet(item: $detail) { row in NodeDetailView(entry: row.entry) }
            .sheet(isPresented: $showExport) { if let exportURL { ActivitySheet(items: [exportURL]) } }
        }
    }

    private var overview: some View {
        let recommended = model.ranked().filter(\.recommended)
        return HStack(spacing: 12) {
            Image(systemName: "scope").font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("稳定低延迟档").font(.subheadline.weight(.semibold))
                Text(recommended.isEmpty ? "多轮采样 · 失败率 · P95 · 抖动" : "仅根据当前网络档案的近期结果推荐")
                    .font(.caption2).opacity(0.75)
            }
            Spacer(minLength: 4)
            Text("\(recommended.count)").font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("个").font(.caption)
        }
        .padding(16).foregroundStyle(.white)
        .background(Theme.navy, in: RoundedRectangle(cornerRadius: 16))
    }

    private var networkPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: model.networkKind.icon).foregroundStyle(Theme.accent)
            Menu {
                ForEach(model.vault.networkProfiles.filter { $0.kind == model.networkKind }) { profile in
                    Button { model.selectProfile(profile) } label: {
                        if profile.id == model.activeProfile?.id { Label(profile.name, systemImage: "checkmark") }
                        else { Text(profile.name) }
                    }
                }
            } label: {
                HStack { Text(model.activeNetworkName).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }
            }.disabled(model.running)
            Spacer(minLength: 4)
            Text("手动档案").font(.caption2).foregroundStyle(.secondary)
        }.font(.subheadline).padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("currentNetworkProfile")
    }

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupChip("全部", id: nil, count: model.allEntries.count)
                ForEach(model.vault.subscriptions) { subscription in
                    groupChip(subscription.name, id: subscription.id, count: subscription.nodes.count)
                }
            }
        }
    }

    private func groupChip(_ name: String, id: UUID?, count: Int) -> some View {
        Button { model.selectedGroup = id } label: {
            HStack(spacing: 6) { Text(name); Text("\(count)").opacity(0.65) }
                .font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(model.selectedGroup == id ? Color.white : Color.primary)
                .background(model.selectedGroup == id ? Theme.accent : Theme.card, in: Capsule())
        }.buttonStyle(.plain)
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索节点、IP 或协议", text: $model.query).font(.subheadline)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }.padding(13).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("可测 \(model.testableEntries.count)").font(.subheadline.weight(.semibold))
                NavigationLink { ExclusionsView() } label: {
                    Label("已排除 \(model.excludedCount)", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                }.accessibilityIdentifier("openExclusions")
                Spacer()
                Menu {
                    Picker("排序", selection: $model.settings.sort) {
                        ForEach(NodeSort.allCases, id: \.self) { sort in Text(sort.rawValue).tag(sort) }
                    }
                } label: { Label(model.settings.sort.rawValue, systemImage: "arrow.up.arrow.down").font(.caption.weight(.medium)) }
            }
            if model.excludedCount > 0 {
                Toggle("显示已排除节点（仍跳过测速）", isOn: $model.showExcluded).font(.caption)
                    .accessibilityIdentifier("showExcluded")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: model.allEntries.isEmpty ? "square.stack.3d.up.badge.a" : "magnifyingglass").font(.system(size: 38)).foregroundStyle(Theme.accent)
            Text(model.allEntries.isEmpty ? "从一个订阅开始" : "没有匹配的节点").font(.headline)
            Text(model.allEntries.isEmpty ? "添加订阅地址，或粘贴 Clash 配置与节点分享链接。" : "试试修改搜索，或到排除设置恢复节点。").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.allEntries.isEmpty {
                Button("添加订阅") { adding = true }.buttonStyle(.borderedProminent).disabled(model.running || model.importing)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 44).padding(.horizontal, 16)
    }

    private var testBar: some View {
        VStack(spacing: 8) {
            if !model.running, let checkpoint = model.vault.pausedBatch {
                VStack(spacing: 6) {
                    HStack {
                        let profileName = model.vault.networkProfiles.first { $0.id == checkpoint.profileID }?.name ?? "原网络"
                        Text("未完成 \(checkpoint.remainingEntryIDs.count) 个 · \(profileName)").font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("继续") { model.resume() }.font(.caption.weight(.semibold))
                            .disabled(checkpoint.profileID != model.activeProfile?.id || model.importing || !model.online)
                        Button("放弃", role: .destructive) { model.discardPaused() }.font(.caption)
                    }
                    Text("沿用原任务设置 · 下载\(checkpoint.settings.downloadEnabled ? "开启" : "关闭") · \(checkpoint.settings.rounds)轮；已取消节点会重新采样")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if model.running {
                ProgressView(value: Double(model.completed), total: Double(max(1, model.total)))
                HStack {
                    Text(model.stopping ? "正在停止…" : "测试中 · \(model.completed)/\(model.total)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.backgroundStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                HStack {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.circle")
                        Text("同时测下载").font(.subheadline)
                        Text(model.settings.downloadEnabled ? "每节点最多读取 \(model.settings.downloadMiB) MiB" : "已关闭 · 自动记忆")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Toggle("同时测下载", isOn: $model.settings.downloadEnabled)
                        .labelsHidden().fixedSize()
                        .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                        .accessibilityIdentifier("downloadToggle")
                }
            }
            Button {
                if model.running { model.stop() } else { model.start() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.running ? "stop.fill" : "play.fill")
                    Text(model.running ? (model.stopping ? "正在停止" : "停止测试") : "开始新测试 · \(model.testableEntries.count) 个节点").fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(model.running ? Color.orange : Theme.accent, in: RoundedRectangle(cornerRadius: 15))
            .disabled((!model.running && model.vault.pausedBatch != nil) || model.stopping || (!model.running && (model.testableEntries.isEmpty || model.importing || model.vaultReadFailed)))
            .opacity(!model.running && model.testableEntries.isEmpty ? 0.5 : 1)
        }.padding(.horizontal, 14).padding(.vertical, 10).background(.regularMaterial)
    }
}

struct NodeCard: View {
    var row: RankedNode
    var testing: Bool
    var excluded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.entry.node.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                if excluded { Text("已排除").font(.caption2).foregroundStyle(.secondary) }
                else if testing { ProgressView().scaleEffect(0.75) }
                else if row.recommended {
                    Text(row.established ? "推荐" : "初步推荐").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                } else if row.latest != nil && !row.fresh { Text("需重测").font(.caption2).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if let record = row.latest {
                HStack(spacing: 10) {
                    metric("延迟", value: record.metrics.medianMS.ms + " ms")
                    metric("抖动", value: record.metrics.successes > 0 ? String(format: "%.0f ms", record.metrics.jitterMS) : "—")
                    metric("失败", value: record.metrics.attempts > 0 ? String(format: "%.0f%%", record.metrics.failureRate * 100) : "—")
                    Spacer(minLength: 0)
                    Text(row.score.oneDecimal).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 6) {
                Text("\(row.entry.subscription.name) · \(row.entry.node.kind.uppercased())").lineLimit(1)
                Spacer(minLength: 2)
                if let record = row.latest {
                    if record.error != nil { Text("测试失败").foregroundStyle(.orange) }
                    else if let speed = record.downloadMbps { Text("↓ \(speed.oneDecimal) Mbps").monospacedDigit() }
                    else if record.downloadError != nil { Text("下载失败").foregroundStyle(.orange) }
                } else { Text(testing ? "采样中…" : "未测") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(row.recommended ? Theme.accent.opacity(0.3) : Color.clear, lineWidth: 1))
        .opacity(excluded ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }
    private func metric(_ title: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }.font(.system(size: 11))
    }
}

struct NodeDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var entry: NodeEntry
    @State private var allNetworks = false
    private var history: [Measurement] { model.history(for: entry, allNetworks: allNetworks) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("订阅", value: entry.subscription.name)
                    LabeledContent("协议", value: entry.node.kind.uppercased())
                    LabeledContent("服务器", value: "\(entry.node.server):\(entry.node.port)")
                }
                Section("测速范围") {
                    Toggle("排除此节点", isOn: Binding(get: { model.preferences.excludedNodes.contains(entry.id) }, set: { excluded in
                        if excluded { model.excludeNode(entry) } else { model.includeNode(entry) }
                    })).disabled(model.running)
                    let server = TestPreferences.normalizedServer(entry.node.server)
                    Button(model.preferences.excludedServers.contains(server) ? "恢复此服务器参与测速" : "排除此服务器的所有节点") {
                        if model.preferences.excludedServers.contains(server) { model.preferences.excludedServers.remove(server) }
                        else { model.excludeServer(entry) }
                    }.disabled(model.running)
                    if model.preferences.excludes(entry) {
                        Text("此节点当前被排除，不参与测速或推荐。若恢复后仍排除，请检查地区与服务器规则。").font(.caption).foregroundStyle(.orange)
                    }
                    NavigationLink("查看全部排除规则") { ExclusionsView() }
                }
                Section {
                    LabeledContent("当前网络档案", value: model.activeNetworkName)
                    Toggle("查看所有网络历史", isOn: $allNetworks)
                }
                if let latest = history.first {
                    Section("最近一次 · \(model.networkName(for: latest))") {
                        LabeledContent("延迟中位数", value: "\(latest.metrics.medianMS.ms) ms")
                        LabeledContent("P95 延迟", value: "\(latest.metrics.p95MS.ms) ms")
                        LabeledContent("抖动（MAD）", value: latest.metrics.successes > 0 ? "\(String(format: "%.0f", latest.metrics.jitterMS)) ms" : "—")
                        LabeledContent("成功样本", value: "\(latest.metrics.successes) / \(latest.metrics.attempts)")
                        LabeledContent("单次评分", value: latest.metrics.score.oneDecimal)
                        LabeledContent("可靠性置信下界", value: "\(Int(latest.metrics.confidence * 100))%")
                        if let speed = latest.downloadMbps { LabeledContent("下载速度", value: "\(speed.oneDecimal) Mbps") }
                        LabeledContent("下载读取量", value: ByteCountFormatter.string(fromByteCount: latest.downloadedBytes, countStyle: .binary))
                        if let error = latest.error { Text(error).foregroundStyle(.orange) }
                        if let error = latest.downloadError { Text(error).foregroundStyle(.orange) }
                    }
                    if !latest.samples.isEmpty {
                        Section {
                            Chart(Array(latest.samples.enumerated()), id: \.offset) { sample in
                                BarMark(x: .value("轮次", sample.offset + 1), y: .value("延迟 ms", max(5, sample.element)))
                                    .foregroundStyle(sample.element > 0 ? Theme.accent : Color.orange)
                            }.frame(height: 160).padding(.vertical, 8)
                        } header: { Text("延迟样本") } footer: { Text("橙色表示失败。失败样本不计入延迟，另以失败率惩罚评分。") }
                    }
                }
                Section(allNetworks ? "各网络历史记录" : "当前网络 · 最近 30 次") {
                    if history.isEmpty { Text("尚无测速记录").foregroundStyle(.secondary) }
                    ForEach(history) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.date, format: .dateTime.month().day().hour().minute()).font(.subheadline)
                                Text("\(model.networkName(for: record)) · 成功 \(record.metrics.successes)/\(record.metrics.attempts)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(record.metrics.medianMS.ms) ms").monospacedDigit().font(.subheadline)
                        }
                    }
                }
                Section {
                    Button { model.start(entries: [entry]) } label: { Label("重新测试此节点", systemImage: "arrow.clockwise") }
                        .disabled(model.running || model.importing || model.preferences.excludes(entry) || model.vault.pausedBatch != nil)
                    Button { UIPasteboard.general.string = entry.node.name } label: { Label("复制节点名称", systemImage: "doc.on.doc") }
                }
            }
            .navigationTitle(entry.node.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
