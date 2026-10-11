import Foundation
import MLXToolKit

// Brand kits (Docs/CMS-ROADMAP.md, L2). A kit belongs to a company and is revisioned: every edit makes a new,
// immutable revision; jobs pin the revision they applied, so old work keeps its provenance when the brand moves on.
// The manifest is a superset of marquee-brand-spec `style.json` 1.1 (company → style → version).

public struct BrandPalette: Sendable, Codable, Equatable {
    public var primary: String?
    public var secondary: String?
    public var tertiary: String?
    public var quaternary: String?
    /// Extra named colours (e.g. "accent": "#00AEEF").
    public var extra: [String: String]?

    public init(primary: String? = nil, secondary: String? = nil, tertiary: String? = nil, quaternary: String? = nil,
                extra: [String: String]? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.quaternary = quaternary
        self.extra = extra
    }

    /// `primary #FF6600, secondary #221100, …` — the palette hint appended to prompts.
    public var description: String {
        var parts: [String] = []
        for (name, hex) in [("primary", primary), ("secondary", secondary), ("tertiary", tertiary), ("quaternary", quaternary)] {
            if let hex { parts.append("\(name) \(hex)") }
        }
        for (name, hex) in (extra ?? [:]).sorted(by: { $0.key < $1.key }) { parts.append("\(name) \(hex)") }
        return parts.joined(separator: ", ")
    }
}

public struct BrandTextColours: Sendable, Codable, Equatable {
    public var onLight: String?
    public var onDark: String?
    public var mutedOnLight: String?
    public var mutedOnDark: String?

    public init(onLight: String? = nil, onDark: String? = nil, mutedOnLight: String? = nil, mutedOnDark: String? = nil) {
        self.onLight = onLight
        self.onDark = onDark
        self.mutedOnLight = mutedOnLight
        self.mutedOnDark = mutedOnDark
    }
}

public struct BrandColour: Sendable, Codable, Equatable {
    public var palette: BrandPalette?
    public var text: BrandTextColours?

    public init(palette: BrandPalette? = nil, text: BrandTextColours? = nil) {
        self.palette = palette
        self.text = text
    }
}

public struct BrandLicence: Sendable, Codable, Equatable {
    public var holder: String?
    public var agreement: String?
    public var scope: String?

    public init(holder: String? = nil, agreement: String? = nil, scope: String? = nil) {
        self.holder = holder
        self.agreement = agreement
        self.scope = scope
    }
}

/// A preferred model and settings for one capability.
public struct BrandModelPreference: Sendable, Codable, Equatable {
    public var capability: Capability
    public var model: ModelID?
    public var steps: Int?
    public var guidance: Double?
    /// Extra package parameters (LoRA stacks, strength, …) passed through as job params.
    public var params: JSONObject?

    public init(capability: Capability, model: ModelID? = nil, steps: Int? = nil, guidance: Double? = nil,
                params: JSONObject? = nil) {
        self.capability = capability
        self.model = model
        self.steps = steps
        self.guidance = guidance
        self.params = params
    }
}

/// How a brand shapes generation.
public struct BrandGeneration: Sendable, Codable, Equatable {
    /// Appended to the user's prompt — or, if it contains `{prompt}`, the template the prompt is placed into.
    public var stylePrompt: String?
    public var negativePrompt: String?
    /// Append the palette to the prompt ("Colour palette: primary #FF6600, …").
    public var paletteHint: Bool
    public var preferred: [BrandModelPreference]
    /// Asset roles passed to `imageEdit` as reference images (e.g. ["logo", "reference"]).
    public var referenceRoles: [String]

    public init(stylePrompt: String? = nil, negativePrompt: String? = nil, paletteHint: Bool = true,
                preferred: [BrandModelPreference] = [], referenceRoles: [String] = []) {
        self.stylePrompt = stylePrompt
        self.negativePrompt = negativePrompt
        self.paletteHint = paletteHint
        self.preferred = preferred
        self.referenceRoles = referenceRoles
    }

    enum CodingKeys: String, CodingKey {
        case stylePrompt = "style_prompt"
        case negativePrompt = "negative_prompt"
        case paletteHint = "palette_hint"
        case preferred
        case referenceRoles = "reference_roles"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stylePrompt = try c.decodeIfPresent(String.self, forKey: .stylePrompt)
        negativePrompt = try c.decodeIfPresent(String.self, forKey: .negativePrompt)
        paletteHint = try c.decodeIfPresent(Bool.self, forKey: .paletteHint) ?? true
        preferred = try c.decodeIfPresent([BrandModelPreference].self, forKey: .preferred) ?? []
        referenceRoles = try c.decodeIfPresent([String].self, forKey: .referenceRoles) ?? []
    }
}

/// One asset in a kit, with its brand role (logo, mark, lockup, wordmark, icon, backing, pattern, font, reference,
/// guideline) and variant (primary, mono-light, mono-dark, horizontal, stacked, …).
public struct BrandAssetRef: Sendable, Codable, Equatable {
    public var assetID: AssetID
    public var role: String
    public var variant: String?
    /// The id the asset had in an imported `style.json`.
    public var sourceID: String?

    public init(assetID: AssetID, role: String, variant: String? = nil, sourceID: String? = nil) {
        self.assetID = assetID
        self.role = role
        self.variant = variant
        self.sourceID = sourceID
    }

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case role, variant
        case sourceID = "source_id"
    }
}

/// A brand kit revision's content. Superset of `style.json` 1.1: `colour`, `fonts` (passed through) and `licence`
/// keep their style.json shapes.
public struct BrandManifest: Sendable, Codable, Equatable {
    public var displayName: String?
    public var colour: BrandColour?
    /// style.json `fonts` block, kept verbatim (the font files themselves are `role: font` assets).
    public var fonts: JSONValue?
    public var licence: BrandLicence?
    /// Short, agent-readable brand rules ("Never place the logo on red", "Always sentence case").
    public var rules: [String]
    public var generation: BrandGeneration?
    public var assets: [BrandAssetRef]
    /// When imported from a style.json: its (company, style, version).
    public var source: JSONObject?

    public init(displayName: String? = nil, colour: BrandColour? = nil, fonts: JSONValue? = nil,
                licence: BrandLicence? = nil, rules: [String] = [], generation: BrandGeneration? = nil,
                assets: [BrandAssetRef] = [], source: JSONObject? = nil) {
        self.displayName = displayName
        self.colour = colour
        self.fonts = fonts
        self.licence = licence
        self.rules = rules
        self.generation = generation
        self.assets = assets
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case displayName, colour, fonts, licence, rules, generation, assets, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        colour = try c.decodeIfPresent(BrandColour.self, forKey: .colour)
        fonts = try c.decodeIfPresent(JSONValue.self, forKey: .fonts)
        licence = try c.decodeIfPresent(BrandLicence.self, forKey: .licence)
        rules = try c.decodeIfPresent([String].self, forKey: .rules) ?? []
        generation = try c.decodeIfPresent(BrandGeneration.self, forKey: .generation)
        assets = try c.decodeIfPresent([BrandAssetRef].self, forKey: .assets) ?? []
        source = try c.decodeIfPresent(JSONObject.self, forKey: .source)
    }
}

public struct BrandKitInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var slug: String
    public var name: String
    public var companyID: String
    public var companySlug: String
    /// The revision shown (current, unless a specific one was asked for).
    public var revision: Int
    public var currentRevision: Int
    public var manifest: BrandManifest
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(id: String, slug: String, name: String, companyID: String, companySlug: String, revision: Int,
                currentRevision: Int, manifest: BrandManifest, note: String?, createdAt: Date, updatedAt: Date,
                archivedAt: Date?) {
        self.id = id
        self.slug = slug
        self.name = name
        self.companyID = companyID
        self.companySlug = companySlug
        self.revision = revision
        self.currentRevision = currentRevision
        self.manifest = manifest
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    /// `company/kit@revision` — how provenance and agents refer to it.
    public var reference: String { "\(companySlug)/\(slug)@\(revision)" }

    enum CodingKeys: String, CodingKey {
        case id, slug, name
        case companyID = "company_id"
        case companySlug = "company_slug"
        case revision
        case currentRevision = "current_revision"
        case manifest, note
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }
}

/// Which parts of a brand a job applies. `auto` = everything that makes sense for the capability.
public enum BrandAspect: String, Sendable, Codable, CaseIterable {
    case style, negative, palette, model, params, references
}

/// What a brand did to a job — frozen at submit, recorded in provenance (and the PNG text chunk).
public struct BrandApplication: Sendable, Codable, Equatable {
    public var kitID: String
    /// `company/kit@revision`
    public var reference: String
    public var revision: Int
    /// How the kit was chosen: `explicit`, `project`, or `company`.
    public var resolvedBy: String
    public var applied: [BrandAspect]
    public var userPrompt: String?
    public var effectivePrompt: String?
    public var effectiveNegative: String?
    /// `brand` when the brand's preferred model was used; `caller` / `default` otherwise.
    public var modelSource: String
    /// Brand-supplied parameters (used only where the caller set none).
    public var params: JSONObject
    public var referenceInputs: [AssetID]
    /// Anything that was asked but not applied, and why (e.g. a restricted preferred model without the opt-in).
    public var notes: [String]
    /// Who owns the kit, when it isn't this library's own: a kit shared from another Desktop names its owner, a person
    /// or a department (Pixel Agency Desktop SHARE-9), e.g. "Brand".
    public var owner: String?

    public init(kitID: String, reference: String, revision: Int, resolvedBy: String, applied: [BrandAspect],
                userPrompt: String?, effectivePrompt: String?, effectiveNegative: String?, modelSource: String,
                params: JSONObject, referenceInputs: [AssetID], notes: [String], owner: String? = nil) {
        self.kitID = kitID
        self.reference = reference
        self.revision = revision
        self.resolvedBy = resolvedBy
        self.applied = applied
        self.userPrompt = userPrompt
        self.effectivePrompt = effectivePrompt
        self.effectiveNegative = effectiveNegative
        self.modelSource = modelSource
        self.params = params
        self.referenceInputs = referenceInputs
        self.notes = notes
        self.owner = owner
    }

    enum CodingKeys: String, CodingKey {
        case kitID = "kit_id"
        case reference, revision
        case resolvedBy = "resolved_by"
        case applied
        case userPrompt = "user_prompt"
        case effectivePrompt = "effective_prompt"
        case effectiveNegative = "effective_negative"
        case modelSource = "model_source"
        case params
        case referenceInputs = "reference_inputs"
        case notes, owner
    }
}

// MARK: - Collections

public enum CollectionKind: String, Sendable, Codable {
    /// Manual, ordered, nestable.
    case folder
    /// A saved structured query, evaluated live.
    case smart
}

public struct CollectionInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var slug: String
    public var name: String
    public var kind: CollectionKind
    public var parentID: String?
    public var companyID: String?
    /// Smart collections only.
    public var query: AssetQuery?
    public var assetCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, slug: String, name: String, kind: CollectionKind, parentID: String?, companyID: String?,
                query: AssetQuery?, assetCount: Int, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.slug = slug
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.companyID = companyID
        self.query = query
        self.assetCount = assetCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, name, kind
        case parentID = "parent_id"
        case companyID = "company_id"
        case query
        case assetCount = "asset_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
