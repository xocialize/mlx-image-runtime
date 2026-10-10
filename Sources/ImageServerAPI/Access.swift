import Foundation

// Network access (M5): loopback by default; LAN mode is opt-in, needs a bearer key from other machines, and is
// advertised over Bonjour. Browsers are refused unless their origin is on the CORS allowlist.

/// An API key as the server remembers it. The key itself is shown once, at creation, and never stored — only its
/// SHA-256 digest.
public struct APIKeyInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// The first characters of the key (`mis_ab12…`), so people can tell keys apart.
    public var prefix: String
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: String, label: String, prefix: String, createdAt: Date, lastUsedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.prefix = prefix
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, label, prefix
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

/// Network settings people change (persisted). LAN mode applies on the next launch: the listener binds once.
public struct NetworkSettings: Sendable, Codable, Equatable {
    public var lanMode: Bool
    /// Browser origins allowed to call the API (`https://studio.example.com`, `http://localhost:5173`). Empty = no
    /// browser access; requests carrying any other `Origin` are refused.
    public var corsOrigins: [String]

    public init(lanMode: Bool = false, corsOrigins: [String] = []) {
        self.lanMode = lanMode
        self.corsOrigins = corsOrigins
    }

    enum CodingKeys: String, CodingKey {
        case lanMode = "lan_mode"
        case corsOrigins = "cors_origins"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lanMode = try c.decodeIfPresent(Bool.self, forKey: .lanMode) ?? false
        corsOrigins = try c.decodeIfPresent([String].self, forKey: .corsOrigins) ?? []
    }
}

/// Bonjour advertisement of a LAN-mode server.
public enum ServerAdvertisement {
    /// `_mlximg._tcp` — service names are at most 15 characters.
    public static let serviceType = "_mlximg._tcp"
    /// TXT `v`: the wire protocol, bumped only by breaking API changes.
    public static let protocolVersion = "1"
}
