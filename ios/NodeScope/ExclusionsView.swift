import SwiftUI

struct ExclusionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var server = ""
    @State private var resetting = false
    var body: some View {
        Form {
            Section {
                ForEach(NodeRegion.all) { region in
                    Toggle(isOn: Binding(get: { model.preferences.excludedRegions.contains(region.id) }, set: { excluded in
                        if excluded { model.preferences.excludedRegions.insert(region.id) }
                        else { model.preferences.excludedRegions.remove(region.id) }
                    })) {
                        HStack {
                            Text(region.title)
                            Spacer()
                            Text("\(model.allEntries.filter { NodeRegion.matches(name: $0.node.name).contains { $0.id == region.id } }.count) 个")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("excludeRegion_" + region.id)
                }
            } header: { Text("跳过地区 · 开启即排除") } footer: {
                Text("按节点名称中的地区、旗帜和常见英文缩写匹配，不是 IP 地理定位。多地区或中转名称可能同时匹配；节点命名不准确时，可按节点或服务器精确排除。地区规则对所有订阅生效，并在更新订阅后继续生效。")
            }
            Section {
                HStack {
                    TextField("IP 或服务器域名，不含端口", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                    Button("添加") {
                        model.preferences.excludedServers.insert(TestPreferences.normalizedServer(server)); server = ""
                    }.disabled(!validServer)
                }
                ForEach(model.preferences.excludedServers.sorted(), id: \.self) { value in
                    HStack {
                        Text(value).font(.subheadline).textSelection(.enabled)
                        Spacer()
                        Button { model.preferences.excludedServers.remove(value) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                    }
                }
            } header: { Text("跳过服务器 / IP") } footer: {
                Text("精确匹配订阅里的服务器字段，跳过所有使用该地址的节点。不查询域名解析后的 IP，也不匹配网段。可在节点详情里直接排除服务器。")
            }
            if !model.preferences.excludedNodes.isEmpty {
                Section("单独跳过的节点") {
                    ForEach(model.preferences.excludedNodes.sorted(), id: \.self) { id in
                        HStack {
                            Text(model.allEntries.first { $0.id == id }?.node.name ?? "已移除节点")
                                .font(.subheadline).lineLimit(1)
                            Spacer()
                            Button("恢复") { model.preferences.excludedNodes.remove(id) }.font(.caption)
                        }
                    }
                }
            }
            Section {
                LabeledContent("当前共排除", value: "\(model.allEntries.filter { model.preferences.excludes($0) }.count) 个节点")
                Button("恢复全部参与测速", role: .destructive) { resetting = true }
            } footer: { Text("排除设置自动记忆，不删除节点与历史。被排除的节点不参加批量测速、单节点测速、续测或推荐。") }
        }
        .disabled(model.running)
        .navigationTitle("测速排除").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除全部地区、服务器与节点排除规则？", isPresented: $resetting, titleVisibility: .visible) {
            Button("清除排除规则", role: .destructive) {
                model.preferences.excludedRegions.removeAll(); model.preferences.excludedServers.removeAll(); model.preferences.excludedNodes.removeAll()
            }
        }
    }
    private var validServer: Bool {
        let value = TestPreferences.normalizedServer(server)
        return !value.isEmpty && !value.contains("/") && !value.contains(where: { $0.isWhitespace }) && !value.contains("@")
    }
}
