import Foundation

struct ProxyNode: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: String
    var server: String
    var port: Int
    var config: String
}

struct Subscription: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var url: String
    var nodes: [ProxyNode]
    var updatedAt = Date()
}

struct ParseResponse: Decodable, Sendable {
    var nodes: [ProxyNode]?
    var skipped: Int?
    var warnings: [String]?
    var error: String?
}

struct Metrics: Codable, Sendable {
    var attempts: Int
    var successes: Int
    var failureRate: Double
    var medianMS: Double
    var p95MS: Double
    var jitterMS: Double
    var score: Double
    var confidence: Double
}

struct DownloadDetails: Codable, Sendable {
    var version: Int
    var connections: Int
    var activeConnections: Int
    var setupMS: Double
    var sampleSeconds: Double
    var measuredBytes: Int64
    var warmupBytes: Int64
    var endToEndMbps: Double
    var shortSample: Bool
    var partialFailure: Bool
}

struct ProbeResponse: Decodable, Sendable {
    var metrics: Metrics?
    var samples: [Double]?
    var downloadMbps: Double?
    var downloadDetails: DownloadDetails?
    var downloadedBytes: Int64?
    var downloadError: String?
    var error: String?
    var cancelled: Bool?
}

struct Measurement: Codable, Identifiable, Sendable {
    var id = UUID()
    var batchID: UUID
    var subscriptionID: UUID
    var nodeID: String
    var date = Date()
    var network: String
    var networkProfileID: UUID?
    var latencyURL: String
    var metrics: Metrics
    var samples: [Double]
    var downloadMbps: Double?
    var downloadDetails: DownloadDetails?
    var downloadedBytes: Int64
    var downloadError: String?
    var error: String?
}

extension Measurement {
    var speedApproximate: Bool { downloadDetails == nil || downloadDetails?.shortSample == true || downloadDetails?.partialFailure == true }
    var speedLabel: String { (speedApproximate ? "≈ " : "") + (downloadMbps?.oneDecimal ?? "—") + " Mbps" }
    var speedMBps: String { ((downloadMbps ?? 0) / 8).oneDecimal + " MB/s" }
    var speedMethodGroup: Int { downloadMbps == nil ? -1 : (downloadDetails?.version == 2 ? 1 : 0) }
    var speedQuality: String {
        guard let details = downloadDetails else { return "旧版含建连均速" }
        if details.partialFailure { return "部分连接失败 · 估计" }
        return details.shortSample ? "短样本估计" : "有效采样 \(details.sampleSeconds.oneDecimal) 秒"
    }
}

enum NodeSort: String, CaseIterable, Codable {
    case recommended = "综合推荐", latency = "最低延迟", stability = "最低失败率", speed = "最高下载", name = "节点名称"
}

struct TestSettings: Codable, Sendable {
    var downloadEnabled = false
    var wifiOnly = true
    var rounds = 8
    var timeoutSeconds = 5
    var intervalMS = 700
    var concurrency = 3
    var latencyURL = "https://www.gstatic.com/generate_204"
    var downloadURL = "https://speed.cloudflare.com/__down?bytes=8388608"
    var downloadMiB = 8
    var downloadSeconds = 4
    var downloadConnections = 1
    var sort = NodeSort.recommended

    init() {}
    enum CodingKeys: String, CodingKey { case downloadEnabled, wifiOnly, rounds, timeoutSeconds, intervalMS, concurrency, latencyURL, downloadURL, downloadMiB, downloadSeconds, downloadConnections, sort }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TestSettings()
        downloadEnabled = try values.decodeIfPresent(Bool.self, forKey: .downloadEnabled) ?? defaults.downloadEnabled
        wifiOnly = try values.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? defaults.wifiOnly
        rounds = try values.decodeIfPresent(Int.self, forKey: .rounds) ?? defaults.rounds
        timeoutSeconds = try values.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        intervalMS = try values.decodeIfPresent(Int.self, forKey: .intervalMS) ?? defaults.intervalMS
        concurrency = try values.decodeIfPresent(Int.self, forKey: .concurrency) ?? defaults.concurrency
        latencyURL = try values.decodeIfPresent(String.self, forKey: .latencyURL) ?? defaults.latencyURL
        downloadURL = try values.decodeIfPresent(String.self, forKey: .downloadURL) ?? defaults.downloadURL
        downloadMiB = try values.decodeIfPresent(Int.self, forKey: .downloadMiB) ?? defaults.downloadMiB
        downloadSeconds = try values.decodeIfPresent(Int.self, forKey: .downloadSeconds) ?? defaults.downloadSeconds
        downloadConnections = try values.decodeIfPresent(Int.self, forKey: .downloadConnections) ?? defaults.downloadConnections
        sort = try values.decodeIfPresent(NodeSort.self, forKey: .sort) ?? defaults.sort
    }

    var optionsJSON: String {
        let options: [String: Any] = ["rounds": rounds, "timeoutSeconds": timeoutSeconds,
            "intervalMS": intervalMS, "latencyURL": latencyURL, "downloadURL": downloadURL,
            "downloadEnabled": downloadEnabled, "downloadBytes": downloadMiB * 1_048_576,
            "downloadSeconds": downloadSeconds, "downloadConnections": downloadConnections]
        return String(data: (try? JSONSerialization.data(withJSONObject: options)) ?? Data(), encoding: .utf8) ?? "{}"
    }
    var valid: Bool {
        func https(_ value: String) -> Bool {
            guard let url = URL(string: value) else { return false }
            return url.scheme == "https" && url.host != nil && url.user == nil
        }
        return https(latencyURL) && (!downloadEnabled || https(downloadURL))
    }
}

struct VaultData: Codable {
    var subscriptions: [Subscription] = []
    var measurements: [Measurement] = []
    var networkProfiles: [NetworkProfile] = []
    var activeProfiles: [String: UUID] = [:]
    var pausedBatch: PausedBatch?

    init() {}
    enum CodingKeys: String, CodingKey { case subscriptions, measurements, networkProfiles, activeProfiles, pausedBatch }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try values.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        measurements = try values.decodeIfPresent([Measurement].self, forKey: .measurements) ?? []
        networkProfiles = try values.decodeIfPresent([NetworkProfile].self, forKey: .networkProfiles) ?? []
        activeProfiles = try values.decodeIfPresent([String: UUID].self, forKey: .activeProfiles) ?? [:]
        pausedBatch = try values.decodeIfPresent(PausedBatch.self, forKey: .pausedBatch)
    }
}

struct NodeEntry: Identifiable {
    var subscription: Subscription
    var node: ProxyNode
    var id: String { subscription.id.uuidString + "/" + node.id }
}

struct RankedNode: Identifiable {
    var entry: NodeEntry
    var latest: Measurement?
    var score: Double
    var historyCount: Int
    var historyAttempts: Int
    var historySpan: TimeInterval
    var fresh: Bool
    var recommended = false
    var id: String { entry.id }
    var established: Bool { historyCount >= 3 && historyAttempts >= 24 && historySpan >= 600 }
}

extension Double {
    var ms: String { self > 0 ? String(format: "%.0f", self) : "—" }
    var oneDecimal: String { String(format: "%.1f", self) }
}
