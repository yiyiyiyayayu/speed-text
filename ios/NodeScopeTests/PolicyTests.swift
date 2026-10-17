import XCTest
@testable import NodeScope

final class PolicyTests: XCTestCase {
    private func entry(_ name: String = "HK 01", server: String = "Example.com") -> NodeEntry {
        let node = ProxyNode(id: "node-1", name: name, kind: "ss", server: server, port: 443, config: "{}")
        return NodeEntry(subscription: Subscription(name: "demo", url: "", nodes: [node]), node: node)
    }

    func testRegionAliasesAndFalseMatches() {
        for name in ["香港 01", "🇭🇰专线", "HK01", "Hong Kong", "HKG-2"] {
            XCTAssertTrue(NodeRegion.matches(name: name).contains { $0.id == "hk" }, name)
        }
        XCTAssertFalse(NodeRegion.matches(name: "Australia").contains { $0.id == "us" })
        XCTAssertFalse(NodeRegion.matches(name: "shkserver").contains { $0.id == "hk" })
        XCTAssertFalse(NodeRegion.matches(name: "US01").contains { $0.id == "sg" })
    }

    func testExclusionsComposeAndPersist() throws {
        let item = entry()
        var preferences = TestPreferences()
        preferences.excludedRegions.insert("hk")
        XCTAssertTrue(preferences.excludes(item))
        preferences.excludedRegions.removeAll()
        preferences.excludedServers.insert(TestPreferences.normalizedServer(" EXAMPLE.COM. "))
        XCTAssertTrue(preferences.excludes(item))
        XCTAssertFalse(preferences.excludes(entry("Tokyo", server: "sub.example.com")))
        preferences.excludedServers.removeAll()
        preferences.excludedNodes.insert(item.id)
        XCTAssertTrue(preferences.excludes(item))
        XCTAssertFalse(preferences.excludes(entry("Tokyo"))) // Other subscription, same underlying node ID.
        let restored = try JSONDecoder().decode(TestPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(restored.excludes(item))
        XCTAssertEqual(TestPreferences.normalizedServer("[2001:db8::1]"), "2001:db8::1")
    }

    func testLegacyVaultLoadsWithoutAssigningOldRecordsToNewNetworks() throws {
        let legacy = Data("{\"subscriptions\":[],\"measurements\":[]}".utf8)
        let vault = try JSONDecoder().decode(VaultData.self, from: legacy)
        XCTAssertTrue(vault.networkProfiles.isEmpty)
        XCTAssertTrue(vault.activeProfiles.isEmpty)
        XCTAssertNil(vault.pausedBatch)
        let item = entry()
        let old = measurement(item, profileID: nil, score: 100)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "networkProfileID")
        let decoded = try JSONDecoder().decode(Measurement.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.networkProfileID)
    }

    func testCheckpointRetainsDownloadSettingsAndNetwork() throws {
        var settings = TestSettings(); settings.downloadEnabled = true; settings.rounds = 16
        let profile = NetworkProfile(name: "Home telecom", kind: .wifi)
        var vault = VaultData()
        vault.networkProfiles = [profile]
        vault.activeProfiles["wifi"] = profile.id
        vault.pausedBatch = PausedBatch(batchID: UUID(), profileID: profile.id, remainingEntryIDs: ["a", "b"], settings: settings)
        let copy = try JSONDecoder().decode(VaultData.self, from: JSONEncoder().encode(vault))
        XCTAssertEqual(copy.pausedBatch?.remainingEntryIDs, ["a", "b"])
        XCTAssertEqual(copy.pausedBatch?.profileID, profile.id)
        XCTAssertEqual(copy.pausedBatch?.settings.downloadEnabled, true)
        XCTAssertEqual(copy.pausedBatch?.settings.rounds, 16)
    }

    private func measurement(_ entry: NodeEntry, profileID: UUID?, score: Double) -> Measurement {
        Measurement(batchID: UUID(), subscriptionID: entry.subscription.id, nodeID: entry.node.id,
            network: "Wi-Fi", networkProfileID: profileID, latencyURL: TestSettings().latencyURL,
            metrics: Metrics(attempts: 8, successes: 8, failureRate: 0, medianMS: 30, p95MS: 40, jitterMS: 2, score: score, confidence: 0.7),
            samples: [30], downloadedBytes: 0)
    }

    @MainActor
    func testRankingIsolatesTwoWiFisCellularAndLegacyHistory() throws {
        let item = entry("Tokyo")
        let home = NetworkProfile(name: "Mobile WiFi", kind: .wifi)
        let office = NetworkProfile(name: "Telecom WiFi", kind: .wifi)
        let mobile = NetworkProfile(name: "Mobile cellular", kind: .cellular)
        var vault = VaultData()
        vault.subscriptions = [item.subscription]
        vault.networkProfiles = [home, office, mobile]
        vault.activeProfiles = ["wifi": home.id, "cellular": mobile.id]
        vault.measurements = [measurement(item, profileID: home.id, score: 60), measurement(item, profileID: office.id, score: 95),
                              measurement(item, profileID: mobile.id, score: 40), measurement(item, profileID: nil, score: 100)]
        let suite = "NodeScope.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(initialVault: vault, observeNetwork: false, defaults: defaults, persist: { _ in })
        model.updateNetwork(kind: .wifi, satisfied: true, signature: "wifi")
        XCTAssertEqual(try XCTUnwrap(model.ranked().first).score, 60, accuracy: 0.001)
        XCTAssertEqual(model.history(for: item).count, 1)
        model.selectProfile(office)
        XCTAssertEqual(try XCTUnwrap(model.ranked().first).score, 95, accuracy: 0.001)
        XCTAssertEqual(model.history(for: item).count, 1)
        model.updateNetwork(kind: .cellular, satisfied: true, signature: "cell")
        XCTAssertEqual(try XCTUnwrap(model.ranked().first).score, 40, accuracy: 0.001)
        model.selectProfile(office) // A Wi-Fi cannot become the active cellular profile.
        XCTAssertEqual(model.activeProfile?.id, mobile.id)
        model.updateNetwork(kind: .wifi, satisfied: true, signature: "wifi")
        XCTAssertEqual(model.activeProfile?.id, office.id)
        model.preferences.excludedRegions.insert("jp")
        model.showExcluded = true
        XCTAssertEqual(model.ranked().count, 1)
        XCTAssertFalse(try XCTUnwrap(model.ranked().first).recommended)
        XCTAssertTrue(model.testableEntries.isEmpty)
        XCTAssertEqual(model.history(for: item, allNetworks: true).count, 4)
        let reloaded = AppModel(initialVault: model.vault, observeNetwork: false, defaults: defaults, persist: { _ in })
        XCTAssertTrue(reloaded.preferences.excludedRegions.contains("jp"))
    }
    @MainActor
    func testBackgroundPausePersistsQueueAndResumesOnlyUnfinishedEntries() async throws {
        let item = entry("Tokyo")
        let profile = NetworkProfile(name: "Home", kind: .wifi)
        var vault = VaultData()
        vault.subscriptions = [item.subscription]; vault.networkProfiles = [profile]
        vault.activeProfiles["wifi"] = profile.id
        let suite = "NodeScope.background." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "probe started")
        started.assertForOverFulfill = false
        let gate = DispatchSemaphore(value: 0)
        let result = ProbeResponse(metrics: measurement(item, profileID: profile.id, score: 80).metrics, samples: [30])
        let model = AppModel(initialVault: vault, observeNetwork: false, defaults: defaults, persist: { _ in }, probe: { _, _, _ in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return result
        })
        model.updateNetwork(kind: .wifi, satisfied: true, signature: "wifi")
        model.preferences.continueInBackground = false
        model.start()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.running)
        model.sceneChanged(.background)
        XCTAssertTrue(model.stopping)
        XCTAssertEqual(model.vault.pausedBatch?.remainingEntryIDs, [item.id])
        gate.signal()
        for _ in 0..<200 where model.running { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.vault.measurements.isEmpty) // A result racing with pause must not be scored.
        model.sceneChanged(.active)
        gate.signal()
        model.resume()
        for _ in 0..<200 where model.running { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.running)
        XCTAssertNil(model.vault.pausedBatch)
        XCTAssertEqual(model.vault.measurements.count, 1)
        XCTAssertEqual(model.vault.measurements.first?.networkProfileID, profile.id)
    }

}
