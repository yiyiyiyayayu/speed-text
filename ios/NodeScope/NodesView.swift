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
                LazyVStack(alignment: .leading, spacing: 16) {
                    overview
                    groupPicker
                    controls
                    let rows = model.ranked()
                    if rows.isEmpty { emptyState }
                    else {
                        ForEach(rows) { row in
                            Button { detail = row } label: { NodeCard(row: row, testing: model.pending.contains(row.id)) }
                                .buttonStyle(.plain)
                        }
                    }
                    Text("结果来自本机当前网络。同一节点会随时间、测试地址和网络变化；多次测试更有参考价值。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(20)
            }
            .background(Theme.background)
            .navigationTitle("NodeScope")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 5) {
                        Circle().fill(model.online ? Theme.accent : .orange).frame(width: 6, height: 6)
                        Text(model.network).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { exportURL = model.exportCSV(); showExport = exportURL != nil } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(model.vault.measurements.isEmpty)
                    Button { adding = true } label: { Image(systemName: "plus") }.disabled(model.running || model.importing)
                }
            }
            .safeAreaInset(edge: .bottom) { testBar }
            .sheet(isPresented: $adding) { AddSubscriptionView() }
            .sheet(item: $detail) { row in NodeDetailView(entry: row.entry) }
            .sheet(isPresented: $showExport) { if let exportURL { ActivitySheet(items: [exportURL]) } }
        }
    }

    private var overview: some View {
        let rows = model.ranked()
        let recommended = rows.filter(\.recommended)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("找到稳定的那一档", systemImage: "scope").font(.subheadline.weight(.medium))
                Spacer()
                Text("ON DEVICE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.3).opacity(0.6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(recommended.isEmpty ? "—" : "\(recommended.count)").font(.system(size: 48, weight: .semibold, design: .rounded))
                Text("个推荐节点").font(.subheadline).opacity(0.8)
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(model.groupEntries.count)").font(.title2.weight(.semibold)).monospacedDigit()
                    Text("当前分组").font(.caption).opacity(0.65)
                }
            }
            Text(recommended.isEmpty ? "多轮采样 · 失败率 · P95 · 抖动" : "\(recommended.first?.entry.node.name ?? "") 等节点进入低延迟稳定档")
                .font(.caption).lineLimit(1).opacity(0.75)
        }
        .padding(22).foregroundStyle(.white)
        .background(LinearGradient(colors: [Theme.navy, Color(red: 0.08, green: 0.25, blue: 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 24))
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
                .font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(model.selectedGroup == id ? Color.white : Color.primary)
                .background(model.selectedGroup == id ? Theme.accent : Theme.card, in: Capsule())
        }.buttonStyle(.plain)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索节点或协议", text: $model.query).font(.subheadline)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }.padding(13).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("节点列表").font(.headline)
                Spacer()
                Menu {
                    Picker("排序", selection: $model.settings.sort) {
                        ForEach(NodeSort.allCases, id: \.self) { sort in Text(sort.rawValue).tag(sort) }
                    }
                } label: { Label(model.settings.sort.rawValue, systemImage: "arrow.up.arrow.down").font(.caption.weight(.medium)) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: model.allEntries.isEmpty ? "square.stack.3d.up.badge.a" : "magnifyingglass").font(.system(size: 38)).foregroundStyle(Theme.accent)
            Text(model.allEntries.isEmpty ? "从一个订阅开始" : "没有匹配的节点").font(.headline)
            Text(model.allEntries.isEmpty ? "添加订阅地址，或粘贴 Clash 配置与节点分享链接。" : "试试其他节点名称或协议。").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.allEntries.isEmpty {
                Button("添加订阅") { adding = true }.buttonStyle(.borderedProminent).disabled(model.running || model.importing)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 44).padding(.horizontal, 16)
    }

    private var testBar: some View {
        VStack(spacing: 10) {
            if model.running {
                ProgressView(value: Double(model.completed), total: Double(max(1, model.total)))
                HStack {
                    Text(model.stopping ? "正在停止…" : "测试中 · \(model.completed)/\(model.total)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("每节点 \(model.settings.rounds) 轮").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Toggle(isOn: $model.settings.downloadEnabled) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.circle")
                        Text("同时测下载").font(.subheadline)
                        Text(model.settings.downloadEnabled ? "每节点最多读取 \(model.settings.downloadMiB) MiB" : "已关闭 · 自动记忆")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            }
            Button {
                if model.running { model.stop() } else { model.start() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.running ? "stop.fill" : "play.fill")
                    Text(model.running ? (model.stopping ? "正在停止" : "停止测试") : "测试当前列表 · \(model.visibleEntries.count) 个节点").fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(model.running ? Color.orange : Theme.accent, in: RoundedRectangle(cornerRadius: 15))
            .disabled(model.stopping || (!model.running && (model.visibleEntries.isEmpty || model.importing || model.vaultReadFailed)))
            .opacity(!model.running && model.visibleEntries.isEmpty ? 0.5 : 1)
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.regularMaterial)
    }
}

struct NodeCard: View {
    var row: RankedNode
    var testing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.09)).frame(width: 42, height: 42)
                    Image(systemName: "network").foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.entry.node.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(row.entry.subscription.name) · \(row.entry.node.kind.uppercased())").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                if testing { ProgressView().padding(7) }
                else if row.recommended {
                    Text(row.established ? "推荐" : "初步推荐").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 6).background(Theme.accent.opacity(0.09), in: Capsule())
                } else if row.latest != nil && !row.fresh {
                    Text("需重测").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let record = row.latest {
                HStack(spacing: 0) {
                    metric("延迟", value: record.metrics.medianMS.ms, unit: "ms")
                    metric("抖动", value: record.metrics.successes > 0 ? record.metrics.jitterMS.ms : "—", unit: "ms")
                    metric("失败率", value: String(format: "%.0f", record.metrics.failureRate * 100), unit: "%")
                    metric("评分", value: row.score.oneDecimal, unit: "")
                }
                if let error = record.error { Text(error).font(.caption).foregroundStyle(.orange) }
                else if let speed = record.downloadMbps {
                    HStack { Image(systemName: "arrow.down"); Text("\(speed.oneDecimal) Mbps"); Spacer(); Text(record.date, style: .time) }.font(.caption2).foregroundStyle(.secondary)
                } else if let error = record.downloadError {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text(testing ? "正在采集多轮样本…" : "等待测速").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(row.recommended ? Theme.accent.opacity(0.25) : Color.clear, lineWidth: 1))
    }
    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NodeDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var entry: NodeEntry
    private var history: [Measurement] { model.history(for: entry) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("订阅", value: entry.subscription.name)
                    LabeledContent("协议", value: entry.node.kind.uppercased())
                    LabeledContent("服务器", value: "\(entry.node.server):\(entry.node.port)")
                }
                if let latest = history.first {
                    Section("最近一次 · \(latest.network)") {
                        LabeledContent("延迟中位数", value: "\(latest.metrics.medianMS.ms) ms")
                        LabeledContent("P95 延迟", value: "\(latest.metrics.p95MS.ms) ms")
                        LabeledContent("抖动（MAD）", value: "\(latest.metrics.jitterMS.ms) ms")
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
                Section("历史记录 · 最近 30 次") {
                    if history.isEmpty { Text("尚无测速记录").foregroundStyle(.secondary) }
                    ForEach(history) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.date, format: .dateTime.month().day().hour().minute()).font(.subheadline)
                                Text("\(record.network) · 成功 \(record.metrics.successes)/\(record.metrics.attempts)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(record.metrics.medianMS.ms) ms").monospacedDigit().font(.subheadline)
                        }
                    }
                }
                Section {
                    Button { model.start(entries: [entry]) } label: { Label("重新测试此节点", systemImage: "arrow.clockwise") }
                        .disabled(model.running || model.importing)
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
