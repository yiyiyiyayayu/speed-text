import SwiftUI

@main
struct NodeScopeApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).tint(Theme.accent)
                .alert("提示", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                    Button("知道了", role: .cancel) { model.notice = nil }
                } message: { Text(model.notice ?? "") }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.02, green: 0.57, blue: 0.49)
    static let navy = Color(red: 0.06, green: 0.13, blue: 0.20)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView {
            NodesView().tabItem { Label("测速", systemImage: "waveform.path.ecg") }
            SubscriptionsView().tabItem { Label("订阅", systemImage: "square.stack.3d.up") }
            SettingsView().tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
    }
}
