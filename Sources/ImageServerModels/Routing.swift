import Foundation
import ImageServerAPI
import MLXToolKit

/// The model a job will run on, as decided at submit.
public struct RoutedModel: Sendable, Equatable {
    public var id: ModelID
    public var packageID: String
    public var capability: Capability
    public var displayName: String
    public var license: LicenseStamp
    public var envelope: SizeEnvelope
    public var defaults: GenerationDefaults
    public var sourceRepo: String
    public var revision: String
    /// Declared resident bytes — drives the keep-warm window (large models unload sooner).
    public var footprintBytes: UInt64?

    public init(id: ModelID, packageID: String, capability: Capability, displayName: String, license: LicenseStamp,
                envelope: SizeEnvelope, defaults: GenerationDefaults, sourceRepo: String, revision: String,
                footprintBytes: UInt64? = nil) {
        self.id = id
        self.packageID = packageID
        self.capability = capability
        self.displayName = displayName
        self.license = license
        self.envelope = envelope
        self.defaults = defaults
        self.sourceRepo = sourceRepo
        self.revision = revision
        self.footprintBytes = footprintBytes
    }
}

/// Chooses a model for a capability. Implemented by `ImageEngineService`; tests substitute a fake.
public protocol ModelRouter: Sendable {
    /// `model == nil` routes only to permissive ∧ prod models. Throws `APIError`.
    func route(_ capability: Capability, model: ModelID?) async throws -> RoutedModel
    func modelID(forPackage packageID: String) async -> ModelID?
    /// Every registered model, for residency reporting and model-level actions (prepare, pin, evict).
    func registeredModels() async -> [RegisteredModel]
}

public struct RegisteredModel: Sendable, Equatable {
    public var id: ModelID
    public var packageID: String
    public var capabilities: [Capability]
    public var footprintBytes: UInt64?

    public init(id: ModelID, packageID: String, capabilities: [Capability], footprintBytes: UInt64?) {
        self.id = id
        self.packageID = packageID
        self.capabilities = capabilities
        self.footprintBytes = footprintBytes
    }
}

/// Licence classification from the engine's allowlists — the single authority, so the app never disagrees with
/// what the engine would block under `.blocking`.
public enum LicenseClassifier {
    public static func stamp(for declaration: LicenseDeclaration, advisories: [String]) -> LicenseStamp {
        let weights = declaration.weightLicenses
        let all = weights + [declaration.portCodeLicense]
        let licenseClass: LicenseClass
        if all.allSatisfy(\.isPermissive) {
            licenseClass = .permissive
        } else if all.allSatisfy({ $0.isPermissive || $0.isEvalAcknowledged }) {
            licenseClass = .evalAcknowledged
        } else {
            licenseClass = .restricted
        }
        var lines = advisories
        if licenseClass != .permissive && lines.isEmpty {
            let restricted = all.filter { !$0.isPermissive }.map(\.identifier).joined(separator: ", ")
            lines = ["Non-commercial or research-only terms: \(restricted). Check the model's licence before any commercial use of its outputs."]
        }
        return LicenseStamp(licenseClass: licenseClass, weightLicenses: weights.map(\.identifier),
                            portCodeLicense: declaration.portCodeLicense.identifier, advisories: lines)
    }
}
