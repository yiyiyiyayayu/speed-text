import Foundation

enum NetworkKind: String, Codable, CaseIterable, Sendable {
    case wifi, cellular, other
    var title: String { self == .wifi ? "Wi-Fi" : self == .cellular ? "蜂窝网络" : "其他网络" }
    var icon: String { self == .wifi ? "wifi" : self == .cellular ? "antenna.radiowaves.left.and.right" : "network" }
}

struct NetworkProfile: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: NetworkKind
}

/// Persist remaining entries before starting sockets, so suspension/termination cannot lose the queue.
struct PausedBatch: Codable, Sendable {
    var batchID: UUID
    var profileID: UUID
    var remainingEntryIDs: [String]
    var settings: TestSettings
    var completedCount: Int?
    var createdAt = Date()
}

struct TestPreferences: Codable, Sendable {
    var excludedRegions: Set<String> = []
    var excludedServers: Set<String> = []
    var excludedNodes: Set<String> = []
    var continueInBackground = true

    func excludes(_ entry: NodeEntry) -> Bool {
        excludedNodes.contains(entry.id)
        || excludedServers.contains(Self.normalizedServer(entry.node.server))
        || NodeRegion.matches(name: entry.node.name).contains { excludedRegions.contains($0.id) }
    }
    static func normalizedServer(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if result.hasPrefix("["), result.hasSuffix("]") { result = String(result.dropFirst().dropLast()) }
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }
}

struct NodeRegion: Identifiable {
    var id: String
    var title: String
    var words: [String]
    var codes: [String]
    static let all: [NodeRegion] = [
        .init(id: "hk", title: "香港", words: ["香港", "🇭🇰", "hong kong", "hongkong"], codes: ["hk", "hkg"]),
        .init(id: "tw", title: "台湾", words: ["台湾", "台灣", "🇹🇼", "taiwan", "taipei"], codes: ["tw", "twn"]),
        .init(id: "jp", title: "日本", words: ["日本", "东京", "東京", "大阪", "🇯🇵", "japan", "tokyo", "osaka"], codes: ["jp", "jpn"]),
        .init(id: "sg", title: "新加坡", words: ["新加坡", "狮城", "獅城", "🇸🇬", "singapore"], codes: ["sg", "sgp"]),
        .init(id: "us", title: "美国", words: ["美国", "美國", "洛杉矶", "洛杉磯", "🇺🇸", "united states", "los angeles"], codes: ["us", "usa"]),
        .init(id: "kr", title: "韩国", words: ["韩国", "韓國", "首尔", "首爾", "🇰🇷", "korea", "seoul"], codes: ["kr", "kor"]),
        .init(id: "gb", title: "英国", words: ["英国", "英國", "伦敦", "倫敦", "🇬🇧", "united kingdom", "london"], codes: ["uk", "gb"]),
        .init(id: "de", title: "德国", words: ["德国", "德國", "法兰克福", "🇩🇪", "germany", "frankfurt"], codes: ["de", "deu"]),
        .init(id: "ca", title: "加拿大", words: ["加拿大", "🇨🇦", "canada", "toronto"], codes: ["ca", "can"]),
        .init(id: "au", title: "澳大利亚", words: ["澳大利亚", "澳洲", "🇦🇺", "australia", "sydney"], codes: ["au", "aus"])
    ]
    private static let codeExpressions: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues: all.map { region in
        let codes = region.codes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return (region.id, try! NSRegularExpression(pattern: "(?<![a-z])(?:" + codes + ")(?![a-z])"))
    })
    static func matches(name: String) -> [NodeRegion] {
        let lower = name.lowercased()
        // Bound abbreviations to avoid e.g. matching US inside "Australia" or HK inside a hostname.
        return all.filter { region in
            region.words.contains { lower.contains($0) } || codeExpressions[region.id]?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
        }
    }
}
