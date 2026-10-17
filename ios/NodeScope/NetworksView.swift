import SwiftUI

struct NetworksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: NetworkProfile?
    @State private var showingEditor = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(model.online ? model.networkKind.title : "当前离线", systemImage: model.networkKind.icon)
                    LabeledContent("当前档案", value: model.activeProfile?.name ?? "等待连接")
                    Text("测速结果、历史和推荐只使用当前档案。连接另一条 Wi-Fi 后，请在下方选择对应档案。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(NetworkKind.allCases, id: \.self) { kind in
                    Section(kind.title) {
                        let profiles = model.vault.networkProfiles.filter { $0.kind == kind }
                        if profiles.isEmpty { Text("尚未建立档案").foregroundStyle(.secondary) }
                        ForEach(profiles) { profile in
                            HStack(spacing: 12) {
                                Button { model.selectProfile(profile) } label: {
                                    Image(systemName: model.activeProfile?.id == profile.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.activeProfile?.id == profile.id ? Theme.accent : Color.secondary)
                                        .font(.title3).padding(.vertical, 8)
                                }
                                .buttonStyle(.borderless).disabled(model.running || kind != model.networkKind || !model.online)
                                .accessibilityLabel("使用网络档案 " + profile.name)
                                NavigationLink {
                                    NetworkHistoryView(profileID: profile.id, title: profile.name)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.name).font(.subheadline.weight(.medium))
                                        let records = model.records(profileID: profile.id)
                                        Text("\(records.count) 条记录" + (records.first.map { " · 最近 " + $0.date.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Button { editing = profile; showingEditor = true } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless).disabled(model.running)
                                    .accessibilityLabel("重命名 " + profile.name)
                            }
                        }
                    }
                }
                if !model.records(profileID: nil).isEmpty {
                    Section {
                        NavigationLink("旧版记录（未区分具体网络）") { NetworkHistoryView(profileID: nil, title: "旧版记录") }
                    } footer: { Text("旧版记录继续保留，不会混入新网络档案的排名。") }
                }
                Section {
                    Text("可建立“移动手机”“家里移动 Wi-Fi”“公司电信 Wi-Fi”等档案。网络类型自动识别，各类型记住上次选择。")
                    Text("全能签安装通常无法取得读取 Wi-Fi 名称所需的授权。本版不读取 SSID，也不自动判断运营商；同类 Wi-Fi 切换需要手动确认档案。检测到网络中断、接口或网关变化时会暂停正在进行的测试。")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("网络档案")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button { editing = nil; showingEditor = true } label: { Image(systemName: "plus") }
                    .disabled(model.running || model.vaultReadFailed).accessibilityIdentifier("addNetwork")
            } }
            .sheet(isPresented: $showingEditor) { NetworkEditor(profile: editing, defaultKind: model.networkKind) }
        }
    }
}

struct NetworkEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var profile: NetworkProfile?
    @State private var name: String
    @State private var kind: NetworkKind
    init(profile: NetworkProfile?, defaultKind: NetworkKind) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _kind = State(initialValue: profile?.kind ?? defaultKind)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("例如：家里电信 Wi-Fi", text: $name).accessibilityIdentifier("networkProfileName")
                Picker("连接类型", selection: $kind) {
                    ForEach(NetworkKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(profile != nil)
                Text("名称由你填写，用于区分运营商与使用地点，不会自动识别运营商。相同类型的新档案保存后会立即设为当前档案。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle(profile == nil ? "新建网络档案" : "重命名网络")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    if let profile { model.renameProfile(profile, name: name); dismiss() }
                    else if model.createProfile(name: name, kind: kind) { dismiss() }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.running)
                    .accessibilityIdentifier("saveNetwork") }
            }
        }
    }
}

struct NetworkHistoryView: View {
    @EnvironmentObject private var model: AppModel
    var profileID: UUID?
    var title: String
    var body: some View {
        List {
            let records = model.records(profileID: profileID)
            Section {
                LabeledContent("已保留记录", value: "\(records.count) 条")
                LabeledContent("下载读取量", value: ByteCountFormatter.string(fromByteCount: records.reduce(0) { $0 + $1.downloadedBytes }, countStyle: .binary))
            }
            Section("测速记录") {
                if records.isEmpty { Text("在此网络档案下测速后，记录会显示在这里。").foregroundStyle(.secondary) }
                ForEach(records) { record in
                    let entry = model.allEntries.first { $0.node.id == record.nodeID && $0.subscription.id == record.subscriptionID }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry?.node.name ?? "已移除节点").font(.subheadline).lineLimit(1)
                            Spacer()
                            Text("\(record.metrics.medianMS.ms) ms").monospacedDigit().font(.subheadline.weight(.medium))
                        }
                        Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · 成功 \(record.metrics.successes)/\(record.metrics.attempts) · 评分 \(record.metrics.score.oneDecimal)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                }
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
