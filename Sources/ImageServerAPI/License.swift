import Foundation

/// How a model's (or an asset's) terms classify. The app is non-commercial, so `restricted` models register and run —
/// but they are never chosen by default routing, and every surface says so.
public enum LicenseClass: String, Sendable, Codable, Comparable, CaseIterable {
    /// Every weight licence and the port-code licence is on the engine's permissive allowlist.
    case permissive
    /// On the engine's eval-acknowledged list (e.g. CircleStone NC) — evaluation use only.
    case evalAcknowledged
    /// Anything else: research-only or non-commercial terms.
    case restricted

    private var rank: Int {
        switch self {
        case .permissive: 0
        case .evalAcknowledged: 1
        case .restricted: 2
        }
    }
    public static func < (a: LicenseClass, b: LicenseClass) -> Bool { a.rank < b.rank }

    /// The most restrictive of several — what a derived asset inherits from its model and inputs.
    public static func mostRestrictive(_ classes: some Sequence<LicenseClass>) -> LicenseClass {
        classes.max() ?? .permissive
    }
}

/// The licence facts frozen onto a job at submit and copied onto every asset it produces.
public struct LicenseStamp: Sendable, Codable, Equatable, Hashable {
    public var licenseClass: LicenseClass
    /// SPDX ids (or `LicenseRef-…`) of the weights.
    public var weightLicenses: [String]
    public var portCodeLicense: String
    /// Human-readable advisory lines; empty for permissive models.
    public var advisories: [String]

    public init(licenseClass: LicenseClass, weightLicenses: [String], portCodeLicense: String, advisories: [String] = []) {
        self.licenseClass = licenseClass
        self.weightLicenses = weightLicenses
        self.portCodeLicense = portCodeLicense
        self.advisories = advisories
    }

    enum CodingKeys: String, CodingKey {
        case licenseClass = "class"
        case weightLicenses = "weight"
        case portCodeLicense = "port_code"
        case advisories
    }

    /// One line for MCP text results and logs, e.g. `permissive (Apache-2.0 weights, MIT code)`.
    public var summary: String {
        let weights = weightLicenses.joined(separator: " + ")
        return "\(licenseClass.rawValue) (\(weights) weights, \(portCodeLicense) code)"
    }
}
