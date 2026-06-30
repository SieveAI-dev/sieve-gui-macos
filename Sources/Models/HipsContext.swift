import Foundation

/// `params.context.template` 五种模板之一，无法识别的降级到 `.generic`
public enum HipsContext: Sendable, Equatable {
    case addressCompare(AddressCompare)
    case signingToolUse(SigningToolUse)
    case markdownExfil(MarkdownExfil)
    case secretOutbound(SecretOutbound)
    case generic(GenericPayload)

    public var templateName: String {
        switch self {
        case .addressCompare: return "address_compare"
        case .signingToolUse: return "signing_tool_use"
        case .markdownExfil: return "markdown_exfil"
        case .secretOutbound: return "secret_outbound"
        case .generic: return "generic_json"
        }
    }

    public struct AddressCompare: Codable, Sendable, Equatable {
        public let originalAddress: String
        public let substitutedAddress: String
        public let chain: String
        public let levenshtein: Int

        enum CodingKeys: String, CodingKey {
            case originalAddress = "original_address"
            case substitutedAddress = "substituted_address"
            case chain
            case levenshtein
        }
    }

    public struct SigningToolUse: Codable, Sendable, Equatable {
        public let toolName: String
        public let chain: String
        public let chainId: Int?
        public let typedData: AnyCodable?
        public let flags: Flags?

        public struct Flags: Codable, Sendable, Equatable {
            public let infiniteAmount: Bool
            public let deadlineZero: Bool
            public let approveAll: Bool

            enum CodingKeys: String, CodingKey {
                case infiniteAmount = "infinite_amount"
                case deadlineZero = "deadline_zero"
                case approveAll = "approve_all"
            }
        }

        enum CodingKeys: String, CodingKey {
            case toolName = "tool_name"
            case chain
            case chainId = "chain_id"
            case typedData = "typed_data"
            case flags
        }
    }

    public struct MarkdownExfil: Codable, Sendable, Equatable {
        public let markdownSnippet: String
        public let urls: [String]
        public let reachable: [Bool]?

        enum CodingKeys: String, CodingKey {
            case markdownSnippet = "markdown_snippet"
            case urls
            case reachable
        }
    }

    public struct SecretOutbound: Codable, Sendable, Equatable {
        public let secretKind: String
        public let prefix4: String
        public let suffix4: String
        public let length: Int
        public let hashShort: String

        enum CodingKeys: String, CodingKey {
            case secretKind = "secret_kind"
            case prefix4
            case suffix4
            case length
            case hashShort = "hash_short"
        }
    }

    public struct GenericPayload: Codable, Sendable, Equatable {
        public let payload: AnyCodable
    }
}

/// JSON-RPC 字段未知透明传输用；HIPS 关闭后必须主动置空 rawJSON。
public struct AnyCodable: Codable, Sendable, Equatable {
    public let rawData: Data

    public init(rawData: Data) { self.rawData = rawData }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(JSONValue.self) {
            self.rawData = (try? JSONEncoder().encode(value)) ?? Data()
        } else {
            self.rawData = Data()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value = (try? JSONDecoder().decode(JSONValue.self, from: rawData)) ?? .null
        try container.encode(value)
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.rawData == rhs.rawData
    }
}

public struct MarkdownExfilPresentation: Sendable, Equatable {
    public struct URLRow: Identifiable, Sendable, Equatable {
        public let id: Int
        public let maskedURL: String
        public let reachable: Bool?

        public var reachabilityLabel: String {
            switch reachable {
            case true: return "reachable"
            case false: return "unreachable"
            case nil: return "unknown"
            }
        }
    }

    public let maskedSnippet: String
    public let urlRows: [URLRow]

    public init(value: HipsContext.MarkdownExfil) {
        var snippet = value.markdownSnippet
        for url in value.urls {
            snippet = snippet.replacingOccurrences(of: url, with: Self.maskURLQuery(url))
        }
        self.maskedSnippet = snippet
        let reachable = value.reachable
        self.urlRows = value.urls.enumerated().map { index, url in
            URLRow(
                id: index,
                maskedURL: Self.maskURLQuery(url),
                reachable: reachable?.indices.contains(index) == true ? reachable?[index] : nil
            )
        }
    }

    public static func maskURLQuery(_ rawURL: String) -> String {
        guard let question = rawURL.firstIndex(of: "?") else { return rawURL }
        let prefix = rawURL[..<question]
        let afterQuestion = rawURL.index(after: question)
        if let fragment = rawURL[afterQuestion...].firstIndex(of: "#") {
            return "\(prefix)?••••\(rawURL[fragment...])"
        }
        return "\(prefix)?••••"
    }
}

/// JSON 树的内部表示（不暴露给 Service 层）
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}
