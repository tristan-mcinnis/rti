import Foundation

/// JSON-RPC 2.0 / Model Context Protocol message shapes.
///
/// We hand-roll a minimal subset rather than depend on a Swift MCP SDK so
/// the `rti-mcp` binary stays small and link-time stable. Only the
/// methods we serve are modelled; unknown methods get a `-32601` reply.

enum MCPProtocolVersion {
    /// Reported in the `initialize` response. Bumped only when the
    /// tool surface changes in a backwards-incompatible way.
    static let supported = "2024-11-05"
}

// MARK: - JSON-RPC envelope

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: AnyCodable?
}

struct JSONRPCResponse: Encodable {
    let jsonrpc: String = "2.0"
    let id: JSONRPCID
    let result: AnyCodable?
    let error: JSONRPCError?

    init(id: JSONRPCID, result: AnyCodable) {
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: JSONRPCID, error: JSONRPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// Notifications have no `id` and expect no response. We don't send any
/// from this server today, but accept them inbound (e.g. `notifications/
/// initialized`) and silently drop.
struct JSONRPCNotification: Decodable {
    let jsonrpc: String
    let method: String
    let params: AnyCodable?
}

enum JSONRPCID: Codable, Hashable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

struct JSONRPCError: Encodable, @unchecked Sendable {
    let code: Int
    let message: String
    let data: AnyCodable?

    init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    static let internalError = JSONRPCError(code: -32603, message: "Internal error")
}

// MARK: - MCP-specific shapes

struct InitializeResult: Encodable {
    let protocolVersion: String
    let serverInfo: ServerInfo
    let capabilities: Capabilities

    struct ServerInfo: Encodable {
        let name: String
        let version: String
    }

    struct Capabilities: Encodable {
        let tools: ToolsCapability
        struct ToolsCapability: Encodable {
            let listChanged: Bool = false
        }
    }
}

struct ToolListing: Encodable {
    let tools: [ToolDescriptor]

    struct ToolDescriptor: Encodable, Sendable {
        let name: String
        let description: String
        let inputSchema: AnyCodable
    }
}

struct ToolCallParams: Decodable {
    let name: String
    let arguments: AnyCodable?
}

struct ToolCallResult: Encodable {
    let content: [ToolContent]
    let isError: Bool

    init(text: String, isError: Bool = false) {
        self.content = [.text(text)]
        self.isError = isError
    }

    enum ToolContent: Encodable {
        case text(String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode("text", forKey: .type)
                try c.encode(s, forKey: .text)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, text
        }
    }
}

// MARK: - AnyCodable

/// Erased Codable wrapper. JSON-RPC params and result fields can be any
/// JSON value; this lets us forward them without modelling every shape.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any?

    init(_ value: Any?) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = nil
        } else if let b = try? c.decode(Bool.self) {
            self.value = b
        } else if let i = try? c.decode(Int.self) {
            self.value = i
        } else if let d = try? c.decode(Double.self) {
            self.value = d
        } else if let s = try? c.decode(String.self) {
            self.value = s
        } else if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map(\.value)
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value)
        } else {
            self.value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        // Bool first, but distinguish a real Bool from an NSNumber-bridged
        // 0/1 — `as Bool` succeeds for both, which would mis-encode integer
        // literals as `false`/`true`. Inspect the concrete type instead.
        if let b = value as? Bool, type(of: value!) == Bool.self {
            try c.encode(b)
            return
        }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            try c.encode(n.boolValue)
            return
        }
        switch value {
        case nil:
            try c.encodeNil()
        case let i as Int:
            try c.encode(i)
        case let d as Double:
            try c.encode(d)
        case let s as String:
            try c.encode(s)
        case let date as Date:
            // Encode dates as ISO-8601 strings — agents read them as text.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(f.string(from: date))
        case let arr as [Any]:
            try c.encode(arr.map(AnyCodable.init))
        case let dict as [String: Any]:
            try c.encode(dict.mapValues(AnyCodable.init))
        default:
            try c.encodeNil()
        }
    }
}
