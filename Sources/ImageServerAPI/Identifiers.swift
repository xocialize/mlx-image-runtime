import Foundation

/// Typed string identifiers. Every id that crosses the wire is a prefixed ULID (`job_…`, `ast_…`), so it sorts
/// by creation time and reads unambiguously in logs, URLs and MCP results.
public protocol PrefixedIdentifier: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible
where RawValue == String {
    static var prefix: String { get }
    init(rawValue: String)
}

extension PrefixedIdentifier {
    public static func make(at date: Date = Date()) -> Self {
        Self(rawValue: prefix + ULID.make(at: date))
    }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct JobID: PrefixedIdentifier {
    public static let prefix = "job_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AssetID: PrefixedIdentifier {
    public static let prefix = "ast_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// `asset://ast_…` — the form inputs and MCP results use to chain one job into the next.
    public var uri: String { "asset://" + rawValue }

    public init?(uri: String) {
        guard uri.hasPrefix("asset://") else { return nil }
        let raw = String(uri.dropFirst("asset://".count))
        guard raw.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: raw)
    }
}

/// A model's stable public id (e.g. `z-image-turbo`). Not an engine `PackageID` — the catalog maps one to the other.
public struct ModelID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Who submitted a job — the API key label on the LAN, `local` on loopback, `ui` from the console.
public struct ClientID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let local = ClientID(rawValue: "local")
    public static let console = ClientID(rawValue: "console")

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Crockford-base32 ULID: 48-bit millisecond time + 80 random bits. Lexicographic order == creation order.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func make(at date: Date = Date()) -> String {
        var ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var time = [Character](repeating: "0", count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            time[i] = alphabet[Int(ms & 31)]
            ms >>= 5
        }
        var rng = SystemRandomNumberGenerator()
        var random = [Character]()
        random.reserveCapacity(16)
        for _ in 0..<16 { random.append(alphabet[Int(rng.next() & 31)]) }
        return String(time) + String(random)
    }
}
