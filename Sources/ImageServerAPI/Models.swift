import Foundation
import MLXToolKit

public enum Maturity: String, Sendable, Codable {
    /// Published and validated in-app — eligible for default routing when permissive.
    case prod
    /// Work in progress — runs only when named.
    case wip
}

/// The largest request a model is measured to serve. Footprints are declared at a size, so admission caps the
/// request at that size rather than running out of memory (AB-L-0202).
public struct SizeEnvelope: Sendable, Codable, Equatable {
    public var maxPixels: Int
    public var multipleOf: Int
    public var maxInputs: Int
    /// The model only renders square images (e.g. Mage-Flow).
    public var requiresSquare: Bool

    public init(maxPixels: Int, multipleOf: Int = 16, maxInputs: Int = 1, requiresSquare: Bool = false) {
        self.maxPixels = maxPixels
        self.multipleOf = multipleOf
        self.maxInputs = maxInputs
        self.requiresSquare = requiresSquare
    }

    enum CodingKeys: String, CodingKey {
        case maxPixels = "max_output_pixels"
        case multipleOf = "multiple_of"
        case maxInputs = "max_inputs"
        case requiresSquare = "requires_square"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxPixels = try c.decode(Int.self, forKey: .maxPixels)
        multipleOf = try c.decodeIfPresent(Int.self, forKey: .multipleOf) ?? 16
        maxInputs = try c.decodeIfPresent(Int.self, forKey: .maxInputs) ?? 1
        requiresSquare = try c.decodeIfPresent(Bool.self, forKey: .requiresSquare) ?? false
    }

    /// Floors to the multiple, then checks the area (and squareness). Returns nil when outside the envelope.
    public func fit(width: Int, height: Int) -> (width: Int, height: Int)? {
        let w = (width / multipleOf) * multipleOf
        let h = (height / multipleOf) * multipleOf
        guard w >= multipleOf, h >= multipleOf, w * h <= maxPixels, !requiresSquare || w == h else { return nil }
        return (w, h)
    }

    /// The largest size with this aspect ratio that fits — for `fit: "clamp"`. Square-only models get the largest
    /// square no bigger than the request's shorter side.
    public func clamp(width: Int, height: Int) -> (width: Int, height: Int) {
        if requiresSquare {
            let side = min(min(width, height), Int(Double(maxPixels).squareRoot()))
            let s = max(multipleOf, (side / multipleOf) * multipleOf)
            return (s, s)
        }
        if let fitted = fit(width: width, height: height) { return fitted }
        let scale = (Double(maxPixels) / Double(max(1, width * height))).squareRoot()
        let w = max(multipleOf, (Int(Double(width) * scale) / multipleOf) * multipleOf)
        let h = max(multipleOf, (Int(Double(height) * scale) / multipleOf) * multipleOf)
        return (w, h)
    }
}

public struct GenerationDefaults: Sendable, Codable, Equatable {
    public var steps: Int?
    public var guidance: Double?
    public var width: Int
    public var height: Int

    public init(steps: Int?, guidance: Double?, width: Int = 1024, height: Int = 1024) {
        self.steps = steps
        self.guidance = guidance
        self.width = width
        self.height = height
    }
}

/// A package `metaData` key a caller may set per request, through `JobSpec.metaData` (AB-A-0191). Each catalog entry
/// declares its own; submit refuses any other key, so nothing reaches a package unchecked. Adapters are not request
/// keys: they wait for the engine's typed adapter contract (AB-D-0155).
public struct RequestKey: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case bool, number, string, array, object
    }

    public var name: String
    public var kind: Kind
    /// The capabilities that take the key.
    public var capabilities: [Capability]
    public var summary: String

    public init(_ name: String, _ kind: Kind, capabilities: [Capability], summary: String) {
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
        self.summary = summary
    }

    /// Whether `value` has this key's JSON type.
    public func accepts(_ value: JSONValue) -> Bool {
        switch (kind, value) {
        case (.bool, .bool), (.number, .number), (.string, .string), (.array, .array), (.object, .object): true
        default: false
        }
    }
}

/// One adapter (LoRA) a model accepts (`ModelInfo.adapters`, AB-A-0191), from the runtime's adapter catalog: the
/// engine-facing descriptor plus what registry format 3 adds for hosts — prompting, licence terms, status and
/// clearance. Name it in `JobSpec.adapters` by `id`.
public struct AdapterInfo: Sendable, Codable, Equatable, Identifiable {
    /// The catalog id, qualified by its registry's namespace (`flux2-klein:tryon`).
    public var id: String
    public var title: String
    /// `plain` (a weight delta) or `ic` (reference-conditioned: it takes conditioning images, see `conditioning`).
    public var kind: String
    public var baseModels: [String]
    public var capabilities: [Capability]
    /// Text the prompt must contain for the adapter to fire.
    public var trigger: String?
    /// The adapter's canonical prompt; without a `{prompt}` placeholder, the prompt for a request that has none.
    public var promptTemplate: String?
    /// The adapter's own licence, an SPDX id (`NOASSERTION` when its author states none).
    public var license: String
    /// `allowed`, `conditional` (see `notice`), `prohibited` or `unknown`: what a commercial-use policy reads.
    public var commercialUse: String
    /// The operator must accept the adapter's terms before it is offered.
    public var licenseGated: Bool
    public var notice: String?
    public var licenseURL: String?
    public var defaultStrength: Double
    /// The range the adapter was validated over; nil = the model's own range applies.
    public var strengthMin: Double?
    public var strengthMax: Double?
    /// Ordered conditioning slots of an `ic` adapter.
    public var conditioning: [AdapterSlot]
    /// Registry status (`verified`, `candidate`, …): review evidence, not a gate.
    public var status: String
    /// Per base model: `perceptual`, `mechanical` or `declared`.
    public var clearance: [String: String]
    /// The file's size, for a download preview.
    public var bytes: UInt64?

    public struct AdapterSlot: Sendable, Codable, Equatable {
        public var role: String
        public var media: String
        public var required: Bool
        public var maxCount: Int
        public var note: String?

        public init(role: String, media: String, required: Bool, maxCount: Int, note: String? = nil) {
            self.role = role
            self.media = media
            self.required = required
            self.maxCount = maxCount
            self.note = note
        }

        enum CodingKeys: String, CodingKey {
            case role, media, required
            case maxCount = "max_count"
            case note
        }
    }

    public init(id: String, title: String, kind: String, baseModels: [String], capabilities: [Capability],
                trigger: String? = nil, promptTemplate: String? = nil, license: String, commercialUse: String,
                licenseGated: Bool = false, notice: String? = nil, licenseURL: String? = nil, defaultStrength: Double,
                strengthMin: Double? = nil, strengthMax: Double? = nil, conditioning: [AdapterSlot] = [],
                status: String, clearance: [String: String] = [:], bytes: UInt64? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.baseModels = baseModels
        self.capabilities = capabilities
        self.trigger = trigger
        self.promptTemplate = promptTemplate
        self.license = license
        self.commercialUse = commercialUse
        self.licenseGated = licenseGated
        self.notice = notice
        self.licenseURL = licenseURL
        self.defaultStrength = defaultStrength
        self.strengthMin = strengthMin
        self.strengthMax = strengthMax
        self.conditioning = conditioning
        self.status = status
        self.clearance = clearance
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case id, title, kind
        case baseModels = "base_models"
        case capabilities, trigger
        case promptTemplate = "prompt_template"
        case license
        case commercialUse = "commercial_use"
        case licenseGated = "license_gated"
        case notice
        case licenseURL = "license_url"
        case defaultStrength = "default_strength"
        case strengthMin = "strength_min"
        case strengthMax = "strength_max"
        case conditioning, status, clearance, bytes
    }
}

public struct ModelState: Sendable, Codable, Equatable {
    public var downloaded: Bool
    public var resident: Bool
    public var residentBytes: UInt64?
    /// Registration or admissibility problem, if any (e.g. "not registered: ineligible on this Mac").
    public var problem: String?

    public init(downloaded: Bool, resident: Bool, residentBytes: UInt64? = nil, problem: String? = nil) {
        self.downloaded = downloaded
        self.resident = resident
        self.residentBytes = residentBytes
        self.problem = problem
    }

    enum CodingKeys: String, CodingKey {
        case downloaded, resident
        case residentBytes = "resident_bytes"
        case problem
    }
}

/// Public description of one servable model.
public struct ModelInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: ModelID
    public var displayName: String
    public var summary: String
    public var capabilities: [Capability]
    /// Capabilities this model is the default route for.
    public var defaultFor: [Capability]
    public var maturity: Maturity
    public var license: LicenseStamp
    public var sourceRepo: String
    public var revision: String
    public var envelope: SizeEnvelope
    public var defaults: GenerationDefaults
    /// Declared resident bytes at the configured quant.
    public var footprintBytes: UInt64?
    public var state: ModelState
    /// The package keys a request may set in `metaData` (AB-A-0191).
    public var requestKeys: [RequestKey]
    /// The adapters (LoRA) this model takes, from the runtime's adapter catalog (AB-A-0191); empty when it takes none.
    public var adapters: [AdapterInfo]

    public init(id: ModelID, displayName: String, summary: String, capabilities: [Capability], defaultFor: [Capability],
                maturity: Maturity, license: LicenseStamp, sourceRepo: String, revision: String,
                envelope: SizeEnvelope, defaults: GenerationDefaults, footprintBytes: UInt64?, state: ModelState,
                requestKeys: [RequestKey] = [], adapters: [AdapterInfo] = []) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.capabilities = capabilities
        self.defaultFor = defaultFor
        self.maturity = maturity
        self.license = license
        self.sourceRepo = sourceRepo
        self.revision = revision
        self.envelope = envelope
        self.defaults = defaults
        self.footprintBytes = footprintBytes
        self.state = state
        self.requestKeys = requestKeys
        self.adapters = adapters
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case summary, capabilities
        case defaultFor = "default_for"
        case maturity, license
        case sourceRepo = "source_repo"
        case revision, envelope, defaults
        case footprintBytes = "footprint_bytes"
        case state
        case requestKeys = "request_keys"
        case adapters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ModelID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        summary = try c.decode(String.self, forKey: .summary)
        capabilities = try c.decode([Capability].self, forKey: .capabilities)
        defaultFor = try c.decode([Capability].self, forKey: .defaultFor)
        maturity = try c.decode(Maturity.self, forKey: .maturity)
        license = try c.decode(LicenseStamp.self, forKey: .license)
        sourceRepo = try c.decode(String.self, forKey: .sourceRepo)
        revision = try c.decode(String.self, forKey: .revision)
        envelope = try c.decode(SizeEnvelope.self, forKey: .envelope)
        defaults = try c.decode(GenerationDefaults.self, forKey: .defaults)
        footprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .footprintBytes)
        state = try c.decode(ModelState.self, forKey: .state)
        // Older servers (before 0.14.0) send none.
        requestKeys = try c.decodeIfPresent([RequestKey].self, forKey: .requestKeys) ?? []
        adapters = try c.decodeIfPresent([AdapterInfo].self, forKey: .adapters) ?? []
    }

    /// Default routing eligibility: permissive weights AND code, and validated.
    public var isDefaultRoutable: Bool { license.licenseClass == .permissive && maturity == .prod }
}
