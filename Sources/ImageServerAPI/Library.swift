import Foundation

// Wire types for the CMS layer (Docs/CMS-ROADMAP.md). Structure — companies, projects, status, rights — lives in
// these types and in columns; tags are the vocabulary people and agents choose.

/// A client of the agency. Called "company" in the API (marquee-brand-spec's word, and `ClientID` already means
/// "API caller"); the console labels it "Client".
public struct CompanyInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var slug: String
    public var name: String
    public var notes: String?
    /// The company's default brand kit (applies to its projects without their own).
    public var defaultBrandKitID: String?
    public var projectCount: Int
    public var assetCount: Int
    public var createdAt: Date
    public var archivedAt: Date?

    public init(id: String, slug: String, name: String, notes: String?, defaultBrandKitID: String? = nil,
                projectCount: Int, assetCount: Int, createdAt: Date, archivedAt: Date?) {
        self.defaultBrandKitID = defaultBrandKitID
        self.id = id
        self.slug = slug
        self.name = name
        self.notes = notes
        self.projectCount = projectCount
        self.assetCount = assetCount
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, name, notes
        case defaultBrandKitID = "default_brand_kit_id"
        case projectCount = "project_count"
        case assetCount = "asset_count"
        case createdAt = "created_at"
        case archivedAt = "archived_at"
    }
}

public struct ProjectInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var slug: String
    public var name: String
    public var description: String?
    public var companyID: String?
    public var companySlug: String?
    public var companyName: String?
    /// The project's own brand kit (else the company default applies).
    public var brandKitID: String?
    public var assetCount: Int
    public var createdAt: Date
    public var archivedAt: Date?

    public init(id: String, slug: String, name: String, description: String?, companyID: String?, companySlug: String?,
                companyName: String?, brandKitID: String? = nil, assetCount: Int, createdAt: Date, archivedAt: Date?) {
        self.brandKitID = brandKitID
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.companyID = companyID
        self.companySlug = companySlug
        self.companyName = companyName
        self.assetCount = assetCount
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    /// `company/project` (or just `project` without a company) — the reference form agents use.
    public var path: String { companySlug.map { "\($0)/\(slug)" } ?? slug }

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description
        case companyID = "company_id"
        case companySlug = "company_slug"
        case companyName = "company_name"
        case brandKitID = "brand_kit_id"
        case assetCount = "asset_count"
        case createdAt = "created_at"
        case archivedAt = "archived_at"
    }
}

/// Per-project review state — "approved for A" isn't "approved for B".
public enum ProjectStatus: String, Sendable, Codable, CaseIterable {
    case draft, review, approved, final, rejected
}

public struct ProjectMembership: Sendable, Codable, Equatable {
    public var projectID: String
    public var slug: String
    public var name: String
    public var companySlug: String?
    public var isHome: Bool
    public var status: ProjectStatus?
    public var role: String?

    public init(projectID: String, slug: String, name: String, companySlug: String?, isHome: Bool,
                status: ProjectStatus?, role: String?) {
        self.projectID = projectID
        self.slug = slug
        self.name = name
        self.companySlug = companySlug
        self.isHome = isHome
        self.status = status
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case slug, name
        case companySlug = "company_slug"
        case isHome = "is_home"
        case status, role
    }
}

/// Who owns the pixels and what may be done with them — a separate axis from the model-weights `LicenseClass`.
public enum RightsClass: String, Sendable, Codable, CaseIterable, Comparable {
    /// Made by us (generated, or our own photography).
    case owned
    /// Openly licensed (CC0, CC-BY, …) — see the credit line.
    case open
    /// Licensed stock or commissioned work with terms.
    case licensed
    /// Belongs to a client; use within their work.
    case clientOwned = "client_owned"
    /// Not yet established. The default for uploads.
    case unknown

    private var rank: Int {
        switch self {
        case .owned: 0
        case .open: 1
        case .licensed: 2
        case .clientOwned: 3
        case .unknown: 4
        }
    }
    public static func < (a: RightsClass, b: RightsClass) -> Bool { a.rank < b.rank }
}

public enum AIUse: String, Sendable, Codable, CaseIterable {
    case allowed, forbidden, unknown
}

public struct AssetRights: Sendable, Codable, Equatable {
    public var rightsClass: RightsClass
    public var holder: String?
    public var expiresAt: Date?
    public var aiUse: AIUse
    /// Free-form terms (licence name/URL, agreement reference, usage scope, source of the claim).
    public var details: JSONObject?

    public init(rightsClass: RightsClass = .unknown, holder: String? = nil, expiresAt: Date? = nil,
                aiUse: AIUse = .unknown, details: JSONObject? = nil) {
        self.rightsClass = rightsClass
        self.holder = holder
        self.expiresAt = expiresAt
        self.aiUse = aiUse
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case rightsClass = "class"
        case holder
        case expiresAt = "expires_at"
        case aiUse = "ai_use"
        case details
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rightsClass = try c.decodeIfPresent(RightsClass.self, forKey: .rightsClass) ?? .unknown
        holder = try c.decodeIfPresent(String.self, forKey: .holder)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        aiUse = try c.decodeIfPresent(AIUse.self, forKey: .aiUse) ?? .unknown
        details = try c.decodeIfPresent(JSONObject.self, forKey: .details)
    }
}

public struct PaletteColor: Sendable, Codable, Equatable {
    public var hex: String
    /// Share of the image (0…1).
    public var weight: Double

    public init(hex: String, weight: Double) {
        self.hex = hex
        self.weight = weight
    }
}

// MARK: - Edits

public struct TagEdit: Sendable, Codable, Equatable {
    public var add: [String]
    public var remove: [String]

    public init(add: [String] = [], remove: [String] = []) {
        self.add = add
        self.remove = remove
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        add = try c.decodeIfPresent([String].self, forKey: .add) ?? []
        remove = try c.decodeIfPresent([String].self, forKey: .remove) ?? []
    }
}

public struct ProjectEdit: Sendable, Codable, Equatable {
    /// Project references (id, slug, or `company/slug`) to add the asset to.
    public var add: [String]
    public var remove: [String]
    /// Make this project the asset's home (adding it if needed).
    public var home: String?
    /// Status (and role) to set on `home` (or on every project in `add`).
    public var status: ProjectStatus?
    public var role: String?

    public init(add: [String] = [], remove: [String] = [], home: String? = nil, status: ProjectStatus? = nil,
                role: String? = nil) {
        self.add = add
        self.remove = remove
        self.home = home
        self.status = status
        self.role = role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        add = try c.decodeIfPresent([String].self, forKey: .add) ?? []
        remove = try c.decodeIfPresent([String].self, forKey: .remove) ?? []
        home = try c.decodeIfPresent(String.self, forKey: .home)
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status)
        role = try c.decodeIfPresent(String.self, forKey: .role)
    }
}

/// A partial update. Absent fields are untouched; an empty string clears a text field.
public struct AssetPatch: Sendable, Codable, Equatable {
    public var name: String?
    public var caption: String?
    public var altText: String?
    public var notes: String?
    public var creator: String?
    public var creditLine: String?
    public var copyright: String?
    public var sourceDetail: String?
    public var rights: AssetRights?
    public var tags: TagEdit?
    public var projects: ProjectEdit?
    /// Optimistic concurrency: the edit fails with 409 if the asset's revision has moved on.
    public var revision: Int?

    public init(name: String? = nil, caption: String? = nil, altText: String? = nil, notes: String? = nil,
                creator: String? = nil, creditLine: String? = nil, copyright: String? = nil,
                sourceDetail: String? = nil, rights: AssetRights? = nil, tags: TagEdit? = nil,
                projects: ProjectEdit? = nil, revision: Int? = nil) {
        self.name = name
        self.caption = caption
        self.altText = altText
        self.notes = notes
        self.creator = creator
        self.creditLine = creditLine
        self.copyright = copyright
        self.sourceDetail = sourceDetail
        self.rights = rights
        self.tags = tags
        self.projects = projects
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case name, caption
        case altText = "alt_text"
        case notes, creator
        case creditLine = "credit_line"
        case copyright
        case sourceDetail = "source_detail"
        case rights, tags, projects, revision
    }
}

/// Metadata supplied with an upload (all optional; IPTC/EXIF fills gaps, never overrides what the caller sent).
public struct UploadMetadata: Sendable, Codable, Equatable {
    public var name: String?
    public var originalFilename: String?
    public var caption: String?
    public var altText: String?
    public var notes: String?
    public var creator: String?
    public var creditLine: String?
    public var copyright: String?
    public var sourceDetail: String?
    public var rights: AssetRights?
    /// Home project reference (id, slug, or `company/slug`).
    public var project: String?
    public var status: ProjectStatus?
    public var role: String?
    /// Company reference when there is no project.
    public var company: String?
    public var tags: [String]

    public init(name: String? = nil, originalFilename: String? = nil, caption: String? = nil, altText: String? = nil,
                notes: String? = nil, creator: String? = nil, creditLine: String? = nil, copyright: String? = nil,
                sourceDetail: String? = nil, rights: AssetRights? = nil, project: String? = nil,
                status: ProjectStatus? = nil, role: String? = nil, company: String? = nil, tags: [String] = []) {
        self.name = name
        self.originalFilename = originalFilename
        self.caption = caption
        self.altText = altText
        self.notes = notes
        self.creator = creator
        self.creditLine = creditLine
        self.copyright = copyright
        self.sourceDetail = sourceDetail
        self.rights = rights
        self.project = project
        self.status = status
        self.role = role
        self.company = company
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case name
        case originalFilename = "original_filename"
        case caption
        case altText = "alt_text"
        case notes, creator
        case creditLine = "credit_line"
        case copyright
        case sourceDetail = "source_detail"
        case rights, project, status, role, company, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        altText = try c.decodeIfPresent(String.self, forKey: .altText)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        creator = try c.decodeIfPresent(String.self, forKey: .creator)
        creditLine = try c.decodeIfPresent(String.self, forKey: .creditLine)
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright)
        sourceDetail = try c.decodeIfPresent(String.self, forKey: .sourceDetail)
        rights = try c.decodeIfPresent(AssetRights.self, forKey: .rights)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        company = try c.decodeIfPresent(String.self, forKey: .company)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

public struct UploadResult: Sendable, Codable, Equatable {
    public var asset: AssetInfo
    /// The same bytes were already filed in the same home project; the existing asset was returned (empty fields
    /// filled, nothing overwritten).
    public var deduplicated: Bool
    /// Other assets with identical bytes.
    public var duplicates: [AssetID]
    /// Visually near-identical assets (perceptual-hash distance ≤ 6).
    public var nearDuplicates: [AssetID]
    /// Fields and tags filled from embedded IPTC/EXIF metadata.
    public var importedFields: [String]
    public var importedTags: [String]

    public init(asset: AssetInfo, deduplicated: Bool, duplicates: [AssetID], nearDuplicates: [AssetID],
                importedFields: [String], importedTags: [String]) {
        self.asset = asset
        self.deduplicated = deduplicated
        self.duplicates = duplicates
        self.nearDuplicates = nearDuplicates
        self.importedFields = importedFields
        self.importedTags = importedTags
    }

    enum CodingKeys: String, CodingKey {
        case asset, deduplicated, duplicates
        case nearDuplicates = "near_duplicates"
        case importedFields = "imported_fields"
        case importedTags = "imported_tags"
    }
}

// MARK: - Tags

public struct TagInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: Int64
    public var name: String
    public var namespace: String
    public var count: Int
    public var mergedInto: String?

    public init(id: Int64, name: String, namespace: String, count: Int, mergedInto: String?) {
        self.id = id
        self.name = name
        self.namespace = namespace
        self.count = count
        self.mergedInto = mergedInto
    }

    enum CodingKeys: String, CodingKey {
        case id, name, namespace, count
        case mergedInto = "merged_into"
    }
}

/// Where a tag assignment came from.
public enum TagOrigin: String, Sendable, Codable {
    case user, agent, api, `import`, auto

    public init(_ origin: JobOrigin) {
        switch origin {
        case .ui: self = .user
        case .mcp: self = .agent
        case .rest, .openai, .cli: self = .api
        }
    }
}

// MARK: - Search

public struct FacetValue: Sendable, Codable, Equatable {
    public var value: String
    public var label: String
    public var count: Int

    public init(value: String, label: String, count: Int) {
        self.value = value
        self.label = label
        self.count = count
    }
}

public struct SearchResult: Sendable, Codable, Equatable {
    public var assets: [AssetInfo]
    public var total: Int
    public var nextCursor: String?
    public var facets: [String: [FacetValue]]

    public init(assets: [AssetInfo], total: Int, nextCursor: String?, facets: [String: [FacetValue]]) {
        self.assets = assets
        self.total = total
        self.nextCursor = nextCursor
        self.facets = facets
    }

    enum CodingKeys: String, CodingKey {
        case assets = "data"
        case total
        case nextCursor = "next_cursor"
        case facets
    }
}

public enum AssetSort: String, Sendable, Codable, CaseIterable {
    case relevance, newest, oldest, name, updated
}
