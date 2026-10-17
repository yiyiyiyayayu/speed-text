import Foundation
import Network
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var vault = VaultData()
    @Published var settings: TestSettings {
        didSet { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "testSettings.v1") } }
    }
    @Published var selectedGroup: UUID?
    @Published var query = ""
    @Published var running = false
    @Published var stopping = false
    @Published var pending: Set<String> = []
    @Published var completed = 0
    @Published var total = 0
    @Published var network = "检测中"
    @Published var online = false
    @Published var onWiFi = false
    @Published var notice: String?
    @Published var importing = false
    @Published var vaultReadFailed = false

    private let monitor = NWPathMonitor()
    private var runID: Int64?
    private var batchTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init() {
        if let data = UserDefaults.standard.data(forKey: "testSettings.v1"),
           let saved = try? JSONDecoder().decode(TestSettings.self, from: data) { settings = saved }
        else { settings = TestSettings() }
        do { vault = try Vault.load() }
        catch { vaultReadFailed = true; notice = "本地数据未能解密，已暂停写入以保护原数据。请解锁设备后重启 App。" }
        monitor.pathUpdateHandler = { [weak self] path in
            let name = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "蜂窝网络" : "其他网络"
            let satisfied = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.running && (self.network != name || !satisfied) {
                    self.stop()
                    self.notice = "网络发生变化，已停止本次测速。请在网络稳定后重新测试。"
                }
                self.network = name; self.online = satisfied; self.onWiFi = wifi
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.nodescope.network"))
    }

    var allEntries: [NodeEntry] {
        vault.subscriptions.flatMap { subscription in subscription.nodes.map { NodeEntry(subscription: subscription, node: $0) } }
    }
    var groupEntries: [NodeEntry] { allEntries.filter { selectedGroup == nil || $0.subscription.id == selectedGroup } }
    var visibleEntries: [NodeEntry] {
        groupEntries.filter { query.isEmpty || $0.node.name.localizedCaseInsensitiveContains(query) || $0.node.kind.localizedCaseInsensitiveContains(query) }
    }
    var totalBytes: Int64 { vault.measurements.reduce(0) { $0 + $1.downloadedBytes } }

    func save() {
        guard !vaultReadFailed else { return }
        do { try Vault.save(vault) }
        catch { notice = "保存失败：\(error.localizedDescription)" }
    }

    func addSubscription(name: String, input: String, remote: Bool) async -> Bool {
        guard !vaultReadFailed, !running, !importing else { return false }
        importing = true
        defer { importing = false }
        do {
            let parsed = try await Task.detached(priority: .userInitiated) { try NativeCore.parse(input, remote: remote) }.value
            if let error = parsed.error { notice = error; return false }
            guard let nodes = parsed.nodes, !nodes.isEmpty else { notice = "订阅中没有节点"; return false }
            vault.subscriptions.append(Subscription(name: name.isEmpty ? "我的订阅" : name, url: remote ? input : "", nodes: nodes))
            save()
            showImportNotice(parsed)
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    func refresh(_ subscription: Subscription) async {
        guard !subscription.url.isEmpty, !running, !importing, !vaultReadFailed else { return }
        importing = true; defer { importing = false }
        do {
            let parsed = try await Task.detached(priority: .userInitiated) { try NativeCore.parse(subscription.url, remote: true) }.value
            if let error = parsed.error { notice = error; return }
            guard let nodes = parsed.nodes, !nodes.isEmpty,
                  let index = vault.subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
            vault.subscriptions[index].nodes = nodes
            vault.subscriptions[index].updatedAt = Date()
            let valid = Set(nodes.map(\.id))
            vault.measurements.removeAll { $0.subscriptionID == subscription.id && !valid.contains($0.nodeID) }
            save(); showImportNotice(parsed)
        } catch { notice = error.localizedDescription }
    }

    private func showImportNotice(_ parsed: ParseResponse) {
        var notes = parsed.warnings ?? []
        if let skipped = parsed.skipped, skipped > 0 { notes.append("已跳过 \(skipped) 个不受支持或配置不完整的节点") }
        if !notes.isEmpty { notice = notes.joined(separator: "\n") }
    }

    func delete(_ subscription: Subscription) {
        guard !running, !importing, !vaultReadFailed else { return }
        vault.subscriptions.removeAll { $0.id == subscription.id }
        vault.measurements.removeAll { $0.subscriptionID == subscription.id }
        if selectedGroup == subscription.id { selectedGroup = nil }
        save()
    }

    func clearHistory() { guard !running else { return }; vault.measurements.removeAll(); save() }

    func history(for entry: NodeEntry) -> [Measurement] {
        vault.measurements.filter { $0.subscriptionID == entry.subscription.id && $0.nodeID == entry.node.id }.sorted { $0.date > $1.date }
    }

    func ranked() -> [RankedNode] {
        let recentCutoff = Date().addingTimeInterval(-24 * 3600)
        let freshCutoff = Date().addingTimeInterval(-30 * 60)
        var rows = visibleEntries.map { entry -> RankedNode in
            let history = history(for: entry).filter { $0.network == network && $0.latencyURL == settings.latencyURL }
            let latest = history.first
            let recent = Array(history.filter { $0.date >= recentCutoff }.prefix(12))
            let average = recent.isEmpty ? 0 : recent.reduce(0) { $0 + $1.metrics.score } / Double(recent.count)
            let currentScore = latest?.metrics.score ?? 0
            // History can smooth ordering but never overrule a failed latest run.
            let blended = latest?.metrics.successes == 0 ? 0 : currentScore * 0.7 + average * 0.3
            return RankedNode(entry: entry, latest: latest, score: blended, historyCount: recent.count,
                              historyAttempts: recent.reduce(0) { $0 + $1.metrics.attempts },
                              historySpan: (recent.first?.date ?? Date()).timeIntervalSince(recent.last?.date ?? Date()),
                              fresh: (latest?.date ?? .distantPast) >= freshCutoff)
        }
        let eligible = rows.filter { row in
            guard row.fresh, !pending.contains(row.id), let m = row.latest?.metrics else { return false }
            return row.latest?.error == nil && m.attempts >= 6 && m.successes > 0 && m.failureRate <= 0.10
        }
        if let bestScore = eligible.map(\.score).max(), let bestMedian = eligible.compactMap({ $0.latest?.metrics.medianMS }).min() {
            for index in rows.indices {
                guard let m = rows[index].latest?.metrics else { continue }
                rows[index].recommended = eligible.contains(where: { $0.id == rows[index].id })
                    && rows[index].score >= bestScore - 8
                    && m.p95MS <= max(bestMedian * 1.6, bestMedian + 60)
                    && m.jitterMS <= max(30, m.medianMS * 0.35)
            }
        }
        return rows.sorted { a, b in
            if (a.latest != nil) != (b.latest != nil) { return a.latest != nil }
            if a.fresh != b.fresh { return a.fresh }
            switch settings.sort {
            case .recommended:
                if a.recommended != b.recommended { return a.recommended }
                if a.score != b.score { return a.score > b.score }
            case .latency:
                let x = a.latest?.metrics.medianMS ?? 0, y = b.latest?.metrics.medianMS ?? 0
                if (x > 0) != (y > 0) { return x > 0 }
                if x != y { return x < y }
            case .stability:
                let hasA = (a.latest?.metrics.successes ?? 0) > 0, hasB = (b.latest?.metrics.successes ?? 0) > 0
                if hasA != hasB { return hasA }
                let x = a.latest?.metrics.failureRate ?? 1, y = b.latest?.metrics.failureRate ?? 1
                if x != y { return x < y }
                let xj = a.latest?.metrics.jitterMS ?? .infinity, yj = b.latest?.metrics.jitterMS ?? .infinity
                if xj != yj { return xj < yj }
            case .speed:
                let x = a.latest?.downloadMbps ?? -1, y = b.latest?.downloadMbps ?? -1
                if x != y { return x > y }
            case .name: break
            }
            return a.entry.node.name.localizedStandardCompare(b.entry.node.name) == .orderedAscending
        }
    }

    func start(entries requested: [NodeEntry]? = nil) {
        guard !running, !importing, !vaultReadFailed else { return }
        guard online else { notice = "当前没有可用网络"; return }
        guard settings.valid else { notice = "请在设置中填写有效的 HTTPS 测试地址"; return }
        if settings.downloadEnabled && settings.wifiOnly && !onWiFi { notice = "下载测速仅限 Wi-Fi，请连接 Wi-Fi 或在设置中关闭此限制"; return }
        let entries = requested ?? visibleEntries
        guard !entries.isEmpty else { return }
        let snapshot = settings
        let networkSnapshot = network
        let batchID = UUID()
        let id = NSNewRun()
        runID = id; running = true; stopping = false; completed = 0; total = entries.count
        pending = Set(entries.map(\.id))
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish NodeScope probes") { [weak self] in
            Task { @MainActor [weak self] in self?.stop() }
        }
        batchTask = Task { [weak self] in
            guard let self else { return }
            let limit = min(max(snapshot.concurrency, 1), 6)
            var next = 0
            await withTaskGroup(of: (NodeEntry, ProbeResponse).self) { group in
                func add(_ entry: NodeEntry) {
                    group.addTask {
                        let response = await Task.detached(priority: .userInitiated) {
                            (try? NativeCore.test(run: id, config: entry.node.config, options: snapshot.optionsJSON))
                                ?? ProbeResponse(error: "测速核心返回异常")
                        }.value
                        return (entry, response)
                    }
                }
                for _ in 0..<min(limit, entries.count) { add(entries[next]); next += 1 }
                for await (entry, response) in group {
                    self.pending.remove(entry.id)
                    self.completed += 1
                    if response.cancelled != true {
                        let fallback = Metrics(attempts: 0, successes: 0, failureRate: 1, medianMS: 0, p95MS: 0, jitterMS: 0, score: 0, confidence: 0)
                        let measurement = Measurement(batchID: batchID, subscriptionID: entry.subscription.id, nodeID: entry.node.id,
                            network: networkSnapshot, latencyURL: snapshot.latencyURL, metrics: response.metrics ?? fallback,
                            samples: response.samples ?? [], downloadMbps: response.downloadMbps,
                            downloadedBytes: response.downloadedBytes ?? 0, downloadError: response.downloadError, error: response.error)
                        self.vault.measurements.insert(measurement, at: 0)
                        // Keep at most 30 records per node, with a global memory bound.
                        let old = self.vault.measurements.indices.filter {
                            self.vault.measurements[$0].nodeID == entry.node.id && self.vault.measurements[$0].subscriptionID == entry.subscription.id
                        }.dropFirst(30)
                        for index in old.reversed() { self.vault.measurements.remove(at: index) }
                        if self.vault.measurements.count > 10_000 { self.vault.measurements = Array(self.vault.measurements.prefix(10_000)) }
                        self.save()
                    }
                    if !self.stopping && next < entries.count { add(entries[next]); next += 1 }
                }
            }
            NSEndRun(id)
            self.runID = nil; self.running = false; self.stopping = false; self.pending = []
            UIApplication.shared.isIdleTimerDisabled = false
            if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
            self.batchTask = nil
        }
    }

    func stop() {
        guard let runID else { return }
        stopping = true
        NSCancelRun(runID)
    }

    func exportCSV() -> URL? {
        func quote(_ value: String) -> String {
            // Prevent spreadsheet formula injection from untrusted node names.
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["订阅,节点,协议,时间,网络,延迟ms,P95ms,抖动ms,失败率,评分,下载Mbps,下载字节"]
        for row in ranked() {
            guard let record = row.latest else { continue }
            let fields = [row.entry.subscription.name, row.entry.node.name, row.entry.node.kind,
                          ISO8601DateFormatter().string(from: record.date), record.network,
                          record.metrics.medianMS.oneDecimal, record.metrics.p95MS.oneDecimal,
                          record.metrics.jitterMS.oneDecimal, String(record.metrics.failureRate), row.score.oneDecimal,
                          record.downloadMbps?.oneDecimal ?? "", String(record.downloadedBytes)]
            lines.append(fields.map(quote).joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NodeScope-测速结果.csv")
        do { try ("\u{feff}" + lines.joined(separator: "\r\n")).write(to: url, atomically: true, encoding: .utf8); return url }
        catch { notice = "导出失败"; return nil }
    }
}
