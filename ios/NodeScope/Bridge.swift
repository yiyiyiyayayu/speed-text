import Foundation

enum NativeCore {
    private static func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type) throws -> T {
        guard let pointer else { throw CoreError.invalidResponse }
        defer { NSFree(pointer) }
        let data = Data(String(cString: pointer).utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    static func parse(_ input: String, remote: Bool) throws -> ParseResponse {
        try input.withCString { value in
            try decode(remote ? NSFetch(value) : NSParse(value), as: ParseResponse.self)
        }
    }

    static func test(run: Int64, config: String, options: String) throws -> ProbeResponse {
        try config.withCString { configPointer in
            try options.withCString { optionsPointer in
                try decode(NSTest(run, configPointer, optionsPointer), as: ProbeResponse.self)
            }
        }
    }
    enum CoreError: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "测速核心返回了无效数据" }
    }
}
