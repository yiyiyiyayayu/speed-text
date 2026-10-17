import Foundation
import Network
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var vault = VaultData()
    @Published var settings: TestSettings {
        didSet { if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "testSettings.v1") } }
    }
    @Published var preferences: TestPreferences {
        didSet { if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "testPreferences.v2") } }
    }
    @Published var showExcluded = false
    @Published var networkKind = NetworkKind.other
    @Published var appInBackground = false
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

    private let probe: @Sendable (Int64, String, String) -> ProbeResponse
    private let persist: (VaultData) throws -> Void
    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()
    private var networkSignature: String?
    private var runID: Int64?
    private var batchTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(initialVault: VaultData? = nil, observeNetwork: Bool = true, defaults: UserDefaults = .standard, persist: @escaping (VaultData) throws -> Void = Vault.save,
         probe: @escaping @Sendable (Int64, String, String) -> ProbeResponse = { run, config, options in
             (try? NativeCore.test(run: run, config: config, options: options)) ?? ProbeResponse(error: "测速核心返回异常")
         }) {
        self.probe = probe
        self.persist = persist
        self.defaults = defaults
        if let data = defaults.data(forKey: "testSettings.v1"),
           let saved = try? JSONDecoder().decode(TestSettings.self, from: data) { settings = saved }
        else { settings = TestSettings() }
        if let data = defaults.data(forKey: "testPreferences.v2"),
           let saved = try? JSONDecoder().decode(TestPreferences.self, from: data) { preferences = saved }
        else { preferences = TestPreferences() }
        if let initialVault { vault = initialVault }
        else {
            do { vault = try Vault.load() }
            catch { vaultReadFailed = true; notice = "本地数据未能解密，已暂停写入以保护原数据。请解锁设备后重启 App。" }
        }
        guard observeNetwork else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: NetworkKind = path.usesInterfaceType(.wifi) ? .wifi : path.usesInterfaceType(.cellular) ? .cellular : .other
            let satisfied = path.status == .satisfied
            // A gateway/interface change can detect some same-type switches. This is NOT a Wi-Fi identity.
            let signature = path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
                + path.gateways.map { String(describing: $0) }.sorted().joined(separator: ",")
                + String(path.isExpensive) + String(path.isConstrained)
            Task { @MainActor [weak self] in self?.updateNetwork(kind: kind, satisfied: satisfied, signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "app.nodescope.network"))
    }

    var activeProfile: NetworkProfile? {
        guard let id = vault.activeProfiles[networkKind.rawValue] else { return nil }
        return vault.networkProfiles.first { $0.id == id && $0.kind == networkKind }
    }
    var activeNetworkName: String { activeProfile?.name ?? networkKind.title }

    func updateNetwork(kind: NetworkKind, satisfied: Bool, signature: String) {
        if running && (networkKind != kind || !satisfied || (networkSignature != nil && networkSignature != signature)) {
            pause(reason: "网络发生变化，已保存未完成队列。请确认网络档案后继续。")
        }
        networkKind = kind; network = kind.title; online = satisfied; onWiFi = kind == .wifi
        networkSignature = signature
        if satisfied && activeProfile == nil && !vaultReadFailed {
            let profile = vault.networkProfiles.first { $0.kind == kind } ?? NetworkProfile(name: kind.title + "（请命名）", kind: kind)
            if !vault.networkProfiles.contains(where: { $0.id == profile.id }) { vault.networkProfiles.append(profile) }
            vault.activeProfiles[kind.rawValue] = profile.id
            save()
        }
    }

    @discardableResult
    func createProfile(name: String, kind: NetworkKind) -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !running, !vaultReadFailed else { return false }
        let profile = NetworkProfile(name: String(cleaned.prefix(50)), kind: kind)
        vault.networkProfiles.append(profile)
        if kind == networkKind { vault.activeProfiles[kind.rawValue] = profile.id }
        return save()
    }
    func selectProfile(_ profile: NetworkProfile) {
        guard !running, profile.kind == networkKind, !vaultReadFailed else { return }
        vault.activeProfiles[networkKind.rawValue] = profile.id; save()
    }
    func renameProfile(_ profile: NetworkProfile, name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !cleaned.isEmpty, let i = vault.networkProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        vault.networkProfiles[i].name = String(cleaned.prefix(50)); save()
    }
    func records(profileID: UUID?) -> [Measurement] {
        vault.measurements.filter { $0.networkProfileID == profileID }.sorted { $0.date > $1.date }
    }
    func networkName(for record: Measurement) -> String {
        if let id = record.networkProfileID, let profile = vault.networkProfiles.first(where: { $0.id == id }) { return profile.name }
        return record.network + (record.networkProfileID == nil ? " · 旧版未分网络" : "")
    }
    func excludeNode(_ entry: NodeEntry) { guard !running else { return }; preferences.excludedNodes.insert(entry.id) }
    func includeNode(_ entry: NodeEntry) { guard !running else { return }; preferences.excludedNodes.remove(entry.id) }
    func excludeServer(_ entry: NodeEntry) { guard !running else { return }; preferences.excludedServers.insert(TestPreferences.normalizedServer(entry.node.server)) }


    var allEntries: [NodeEntry] {
        vault.subscriptions.flatMap { subscription in subscription.nodes.map { NodeEntry(subscription: subscription, node: $0) } }
    }
    var groupEntries: [NodeEntry] { allEntries.filter { selectedGroup == nil || $0.subscription.id == selectedGroup } }
    var matchingEntries: [NodeEntry] {
        groupEntries.filter { query.isEmpty || $0.node.name.localizedCaseInsensitiveContains(query) || $0.node.kind.localizedCaseInsensitiveContains(query) || $0.node.server.localizedCaseInsensitiveContains(query) }
    }
    var visibleEntries: [NodeEntry] { matchingEntries.filter { showExcluded || !preferences.excludes($0) } }
    var testableEntries: [NodeEntry] { matchingEntries.filter { !preferences.excludes($0) } }
    var excludedCount: Int { groupEntries.filter { preferences.excludes($0) }.count }
    var totalBytes: Int64 { vault.measurements.reduce(0) { $0 + $1.downloadedBytes } }

    @discardableResult
    func save() -> Bool {
        guard !vaultReadFailed else { return false }
        do { try persist(vault); return true }
        catch { notice = "保存失败：\(error.localizedDescription)"; return false }
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
            guard save() else { vault.subscriptions.removeLast(); return false }
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
        preferences.excludedNodes = preferences.excludedNodes.filter { !$0.hasPrefix(subscription.id.uuidString + "/") }
        vault.subscriptions.removeAll { $0.id == subscription.id }
        vault.measurements.removeAll { $0.subscriptionID == subscription.id }
        if selectedGroup == subscription.id { selectedGroup = nil }
        save()
    }

    func clearHistory() { guard !running else { return }; vault.measurements.removeAll(); save() }

    func history(for entry: NodeEntry, allNetworks: Bool = false) -> [Measurement] {
        vault.measurements.filter { $0.subscriptionID == entry.subscription.id && $0.nodeID == entry.node.id && (allNetworks || $0.networkProfileID == activeProfile?.id) }.sorted { $0.date > $1.date }
    }

    func ranked() -> [RankedNode] {
        let recentCutoff = Date().addingTimeInterval(-24 * 3600)
        let freshCutoff = Date().addingTimeInterval(-30 * 60)
        let comparable = vault.measurements.filter { activeProfile != nil && $0.networkProfileID == activeProfile?.id && $0.latencyURL == settings.latencyURL }
        let byEntry = Dictionary(grouping: comparable) { $0.subscriptionID.uuidString + "/" + $0.nodeID }
        var rows = visibleEntries.map { entry -> RankedNode in
            let history = (byEntry[entry.id] ?? []).sorted { $0.date > $1.date }
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
            guard !preferences.excludes(row.entry), row.fresh, !pending.contains(row.id), let m = row.latest?.metrics else { return false }
            return row.latest?.error == nil && m.attempts >= 6 && m.successes > 0 && m.failureRate <= 0.10
                && m.jitterMS <= max(30, m.medianMS * 0.35)
                && m.p95MS <= max(m.medianMS * 2, m.medianMS + 100)
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
        guard vault.pausedBatch == nil else { notice = "请先继续或放弃未完成任务。"; return }
        launch(entries: requested ?? testableEntries, snapshot: settings, batchID: UUID())
    }

    func resume() {
        guard let checkpoint = vault.pausedBatch else { return }
        guard checkpoint.profileID == activeProfile?.id else { notice = "请先切换到未完成任务对应的网络档案。"; return }
        let ids = Set(checkpoint.remainingEntryIDs)
        let entries = allEntries.filter { ids.contains($0.id) && !preferences.excludes($0) }
        guard !entries.isEmpty else { discardPaused(); notice = "队列中的节点已被排除或删除。"; return }
        launch(entries: entries, snapshot: checkpoint.settings, batchID: checkpoint.batchID)
    }

    func discardPaused() { guard !running else { return }; vault.pausedBatch = nil; save() }

    private func launch(entries requested: [NodeEntry], snapshot: TestSettings, batchID: UUID) {
        guard !running, !importing, !vaultReadFailed else { return }
        guard !appInBackground else { notice = "请回到前台后启动测速。"; return }
        guard online, let profile = activeProfile else { notice = "当前没有可用网络或网络档案"; return }
        guard snapshot.valid else { notice = "请在设置中填写有效的 HTTPS 测试地址"; return }
        if snapshot.downloadEnabled && snapshot.wifiOnly && !onWiFi { notice = "下载测速仅限 Wi-Fi，请连接 Wi-Fi 或在设置中关闭此限制"; return }
        let entries = requested.filter { !preferences.excludes($0) }
        guard !entries.isEmpty else { notice = "没有可测试节点，请检查排除设置。"; return }
        vault.pausedBatch = PausedBatch(batchID: batchID, profileID: profile.id, remainingEntryIDs: entries.map(\.id), settings: snapshot)
        // Never start sockets if the durable queue could not be written.
        guard save() else { return }
        let id = NSNewRun()
        runID = id; running = true; stopping = false; completed = 0; total = entries.count
        pending = Set(entries.map(\.id))
        UIApplication.shared.isIdleTimerDisabled = true
        batchTask = Task { [weak self] in
            guard let self else { return }
            let probe = self.probe
            let limit = snapshot.downloadEnabled ? 1 : min(max(snapshot.concurrency, 1), 6)
            var next = 0
            await withTaskGroup(of: (NodeEntry, ProbeResponse).self) { group in
                func add(_ entry: NodeEntry) {
                    group.addTask {
                        let response = await Task.detached(priority: .userInitiated) {
                            probe(id, entry.node.config, snapshot.optionsJSON)
                        }.value
                        return (entry, response)
                    }
                }
                for _ in 0..<min(limit, entries.count) { add(entries[next]); next += 1 }
                for await (entry, response) in group {
                    self.pending.remove(entry.id)
                    if response.cancelled != true && !self.stopping {
                        self.completed += 1
                        let fallback = Metrics(attempts: 0, successes: 0, failureRate: 1, medianMS: 0, p95MS: 0, jitterMS: 0, score: 0, confidence: 0)
                        let measurement = Measurement(batchID: batchID, subscriptionID: entry.subscription.id, nodeID: entry.node.id,
                            network: profile.name, networkProfileID: profile.id, latencyURL: snapshot.latencyURL, metrics: response.metrics ?? fallback,
                            samples: response.samples ?? [], downloadMbps: response.downloadMbps,
                            downloadedBytes: response.downloadedBytes ?? 0, downloadError: response.downloadError, error: response.error)
                        self.vault.measurements.insert(measurement, at: 0)
                        // Preserve a separate history budget for each network/node pair.
                        let old = self.vault.measurements.indices.filter {
                            self.vault.measurements[$0].nodeID == entry.node.id && self.vault.measurements[$0].subscriptionID == entry.subscription.id
                                && self.vault.measurements[$0].networkProfileID == profile.id
                        }.dropFirst(30)
                        for index in old.reversed() { self.vault.measurements.remove(at: index) }
                        if self.vault.measurements.count > 10_000 { self.vault.measurements = Array(self.vault.measurements.prefix(10_000)) }
                        self.vault.pausedBatch?.remainingEntryIDs.removeAll { $0 == entry.id }
                        self.save()
                    }
                    if !self.stopping && next < entries.count { add(entries[next]); next += 1 }
                }
            }
            NSEndRun(id)
            self.runID = nil; self.running = false; self.stopping = false; self.pending = []
            if self.vault.pausedBatch?.remainingEntryIDs.isEmpty == true { self.vault.pausedBatch = nil }
            self.save()
            UIApplication.shared.isIdleTimerDisabled = false
            self.endBackgroundContinuation()
            self.batchTask = nil
        }
    }

    func stop() {
        // User stops are final; only lifecycle/network pauses retain a resumable queue.
        guard let runID else { return }
        vault.pausedBatch = nil; save()
        stopping = true; NSCancelRun(runID)
    }
    func pause(reason: String) {
        guard let runID else { return }
        stopping = true; NSCancelRun(runID)
        save(); notice = reason
    }
    func sceneChanged(_ phase: ScenePhase) {
        if phase == .background {
            appInBackground = true
            guard running else { return }
            if preferences.continueInBackground { beginBackgroundContinuation() }
            else { pause(reason: "已保存未完成队列，回到前台可继续测速。") }
        } else if phase == .active {
            appInBackground = false
            endBackgroundContinuation()
        }
    }
    private func beginBackgroundContinuation() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish NodeScope probes") { [weak self] in
            Task { @MainActor [weak self] in
                self?.pause(reason: "系统后台时间已到，未完成节点已保存。回到前台后可继续。")
                self?.endBackgroundContinuation()
            }
        }
        if backgroundTask == .invalid { pause(reason: "系统未分配后台时间，已保存未完成队列。") }
    }
    private func endBackgroundContinuation() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
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
                          ISO8601DateFormatter().string(from: record.date), networkName(for: record),
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
