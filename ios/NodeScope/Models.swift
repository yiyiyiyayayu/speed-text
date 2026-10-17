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

struct ProbeResponse: Decodable, Sendable {
    var metrics: Metrics?
    var samples: [Double]?
    var downloadMbps: Double?
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
    var latencyURL: String
    var metrics: Metrics
    var samples: [Double]
    var downloadMbps: Double?
    var downloadedBytes: Int64
    var downloadError: String?
    var error: String?
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
    var sort = NodeSort.recommended

    var optionsJSON: String {
        let options: [String: Any] = ["rounds": rounds, "timeoutSeconds": timeoutSeconds,
            "intervalMS": intervalMS, "latencyURL": latencyURL, "downloadURL": downloadURL,
            "downloadEnabled": downloadEnabled, "downloadBytes": downloadMiB * 1_048_576,
            "downloadSeconds": downloadSeconds]
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
