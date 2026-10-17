import SwiftUI

struct SubscriptionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var deleting: Subscription?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("按订阅整理，独立更新和测试", systemImage: "square.stack.3d.up").font(.subheadline)
                } footer: { Text("订阅地址和节点凭据加密保存在本机，不上传到 GitHub。") }
                ForEach(model.vault.subscriptions) { subscription in
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(subscription.name).font(.headline)
                                Spacer()
                                Text("\(subscription.nodes.count) 个节点").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(subscription.url.isEmpty ? "本地导入" : (URL(string: subscription.url)?.host ?? "远程订阅"))
                                Spacer()
                                Text(subscription.updatedAt, format: .dateTime.month().day().hour().minute())
                            }.font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 20) {
                                Button { model.selectedGroup = subscription.id; model.start(entries: model.allEntries.filter { $0.subscription.id == subscription.id }) } label: { Label("测速", systemImage: "play.fill") }
                                if !subscription.url.isEmpty {
                                    Button { Task { await model.refresh(subscription) } } label: { Label("更新", systemImage: "arrow.clockwise") }
                                }
                                Spacer()
                                Button(role: .destructive) { deleting = subscription } label: { Image(systemName: "trash") }
                            }.font(.subheadline).buttonStyle(.borderless).disabled(model.running || model.importing || model.vaultReadFailed)
                        }.padding(.vertical, 6)
                    }
                }
                Section {
                    Button { adding = true } label: { Label("添加订阅", systemImage: "plus.circle.fill") }
                        .disabled(model.running || model.importing || model.vaultReadFailed)
                    if model.importing { HStack { ProgressView(); Text("正在下载并解析…").foregroundStyle(.secondary) } }
                }
            }
            .navigationTitle("订阅分组")
            .sheet(isPresented: $adding) { AddSubscriptionView() }
            .alert("删除这个订阅？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let deleting { model.delete(deleting) }; deleting = nil }
            } message: { Text("同时删除此订阅的本机测速记录。") }
        }
    }
}

struct AddSubscriptionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var input = ""
    @State private var remote = true
    @State private var importError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("分组名称") { TextField("例如：主力订阅", text: $name).accessibilityIdentifier("subscriptionName") }
                Section {
                    Picker("导入方式", selection: $remote) {
                        Text("订阅地址").tag(true)
                        Text("粘贴配置").tag(false)
                    }.pickerStyle(.segmented)
                    if remote {
                        TextField("https://…", text: $input, axis: .vertical).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextEditor(text: $input).font(.system(.caption, design: .monospaced)).frame(minHeight: 220)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("subscriptionContent")
                    }
                } footer: {
                    Text(remote ? "仅支持 HTTPS 订阅地址。支持 Clash YAML、Base64 订阅及常见节点分享链接。" : "可粘贴 Clash YAML 或一行一个的节点链接。远程 proxy-providers 不会自动加载。")
                }
                Section {
                    Text("支持 SS / SSR / VMess / VLESS / Trojan / Hysteria / Hysteria2 / TUIC 等协议。具体传输与加密组合以所用核心支持范围为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.importing { HStack { ProgressView(); Text("正在导入…") } }
            }
            .navigationTitle("添加订阅").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.importing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        Task {
                            if await model.addSubscription(name: name.trimmingCharacters(in: .whitespacesAndNewlines), input: input.trimmingCharacters(in: .whitespacesAndNewlines), remote: remote) { dismiss() }
                            else { importError = model.notice ?? "导入失败"; model.notice = nil }
                        }
                    }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.importing || model.running || model.vaultReadFailed)
                        .accessibilityIdentifier("importSubscription")
                }
            }
            .interactiveDismissDisabled(model.importing)
            .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("知道了", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
        }
    }
}
