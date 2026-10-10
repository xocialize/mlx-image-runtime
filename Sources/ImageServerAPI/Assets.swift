import Foundation
import MLXToolKit

public enum AssetSource: String, Sendable, Codable {
    case generated, uploaded, derived
}

public enum AssetKind: String, Sendable, Codable {
    case image, matte, vector, font, document
}

/// How an asset came to be — the provenance row behind every generated image.
public struct GenerationInfo: Sendable, Codable, Equatable {
    public var jobID: JobID
    public var capability: Capability
    public var model: ModelID
    public var packageID: String
    public var sourceRepo: String
    public var revision: String
    public var mode: String?
    public var prompt: String?
    public var negativePrompt: String?
    /// String, not a number: a UInt64 seed can exceed JSON's exact-integer range.
    public var seed: String?
    public var width: Int?
    public var height: Int?
    public var steps: Int?
    public var guidance: Double?
    public var params: JSONObject
    public var inputs: [AssetID]
    public var queueMs: Int?
    public var prepareMs: Int?
    public var runMs: Int?
    public var engineVersion: String
    public var appVersion: String
    public var client: ClientID
    /// The brand kit revision applied, and how (nil when no brand applied).
    public var brand: BrandApplication?

    public init(jobID: JobID, capability: Capability, model: ModelID, packageID: String, sourceRepo: String,
                revision: String, mode: String?, prompt: String?, negativePrompt: String?, seed: String?, width: Int?,
                height: Int?, steps: Int?, guidance: Double?, params: JSONObject, inputs: [AssetID], queueMs: Int?,
                prepareMs: Int?, runMs: Int?, engineVersion: String, appVersion: String, client: ClientID) {
        self.jobID = jobID
        self.capability = capability
        self.model = model
        self.packageID = packageID
        self.sourceRepo = sourceRepo
        self.revision = revision
        self.mode = mode
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.seed = seed
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.params = params
        self.inputs = inputs
        self.queueMs = queueMs
        self.prepareMs = prepareMs
        self.runMs = runMs
        self.engineVersion = engineVersion
        self.appVersion = appVersion
        self.client = client
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case capability, model
        case packageID = "package_id"
        case sourceRepo = "source_repo"
        case revision, mode, prompt
        case negativePrompt = "negative_prompt"
        case seed, width, height, steps, guidance, params, inputs
        case queueMs = "queue_ms"
        case prepareMs = "prepare_ms"
        case runMs = "run_ms"
        case engineVersion = "engine_version"
        case appVersion = "app_version"
        case client, brand
    }
}

/// Public description of one library asset.
public struct AssetInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: AssetID
    public var kind: AssetKind
    public var name: String?
    public var originalFilename: String?
    public var caption: String?
    public var altText: String?
    public var notes: String?
    public var creator: String?
    public var creditLine: String?
    public var copyright: String?
    public var sourceDetail: String?
    public var mimeType: String
    public var width: Int?
    public var height: Int?
    public var orientation: String?
    public var bytes: Int64
    /// `sha256:<hex>` — also the content ETag.
    public var contentHash: String
    public var source: AssetSource
    /// Model-weights licence of whatever generated it (nil for uploads).
    public var license: LicenseStamp?
    public var licenseClass: LicenseClass
    public var rights: AssetRights
    public var companyID: String?
    public var companySlug: String?
    public var projects: [ProjectMembership]
    public var generation: GenerationInfo?
    /// User, agent, API and import tags.
    public var tags: [String]
    /// Auto-captioning tags (low confidence, shown dimmed).
    public var autoTags: [String]
    public var palette: [PaletteColor]
    /// The latest vision-model description (caption, alt text, tags), with the model and licence that wrote it.
    public var description: AssetDescription?
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date?

    public init(id: AssetID, kind: AssetKind, name: String?, originalFilename: String? = nil, caption: String? = nil,
                altText: String? = nil, notes: String? = nil, creator: String? = nil, creditLine: String? = nil,
                copyright: String? = nil, sourceDetail: String? = nil, mimeType: String, width: Int?, height: Int?,
                orientation: String? = nil, bytes: Int64, contentHash: String, source: AssetSource,
                license: LicenseStamp?, licenseClass: LicenseClass = .permissive, rights: AssetRights = AssetRights(),
                companyID: String? = nil, companySlug: String? = nil, projects: [ProjectMembership] = [],
                generation: GenerationInfo?, tags: [String], autoTags: [String] = [], palette: [PaletteColor] = [],
                revision: Int = 1, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.originalFilename = originalFilename
        self.caption = caption
        self.altText = altText
        self.notes = notes
        self.creator = creator
        self.creditLine = creditLine
        self.copyright = copyright
        self.sourceDetail = sourceDetail
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.orientation = orientation
        self.bytes = bytes
        self.contentHash = contentHash
        self.source = source
        self.license = license
        self.licenseClass = licenseClass
        self.rights = rights
        self.companyID = companyID
        self.companySlug = companySlug
        self.projects = projects
        self.generation = generation
        self.tags = tags
        self.autoTags = autoTags
        self.palette = palette
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name
        case originalFilename = "original_filename"
        case caption
        case altText = "alt_text"
        case notes, creator
        case creditLine = "credit_line"
        case copyright
        case sourceDetail = "source_detail"
        case mimeType = "mime_type"
        case width, height, orientation, bytes
        case contentHash = "content_hash"
        case source, license
        case licenseClass = "license_class"
        case rights
        case companyID = "company_id"
        case companySlug = "company_slug"
        case projects, generation, tags
        case autoTags = "auto_tags"
        case palette, revision, description
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// The home project, if any.
    public var home: ProjectMembership? { projects.first(where: \.isHome) }
}

/// A structured library query. Every surface — the console search box, REST `q`, MCP, saved searches — parses into
/// this; saved searches store the structure, never the string.
public struct AssetQuery: Sendable, Equatable, Codable {
    /// Full-text terms (FTS5 over name, caption, prompt, tags, places, credit, notes).
    public var text: String?
    /// All of these tags (normalized; merge aliases resolve).
    public var tags: [String]
    public var excludeTags: [String]
    /// Any of these projects (id, slug or `company/slug`).
    public var projects: [String]
    /// Company id or slug.
    public var company: String?
    /// Only assets with no home project.
    public var inbox: Bool
    /// Membership status (scoped to `projects` when given).
    public var statuses: [ProjectStatus]
    public var excludeStatuses: [ProjectStatus]
    public var source: AssetSource?
    public var kind: AssetKind?
    public var licenseClass: LicenseClass?
    public var rightsClass: RightsClass?
    public var model: ModelID?
    public var capability: Capability?
    public var orientation: String?
    /// Collections (id or slug): folder membership or a smart collection's saved query.
    public var collections: [String] = []
    /// `#rrggbb` (near in Lab) or a colour bucket name (red, orange, yellow, green, teal, blue, purple, pink, brown,
    /// black, white, gray), matched against each image's palette.
    public var colour: String?
    /// Rights expiry: `expired`, `soon` (within 30 days), or `set` (has an expiry).
    public var expiry: String?
    /// Has (true) or lacks (false) a vision-model description: `is:described` / `is:undescribed`.
    public var described: Bool?
    public var createdAfter: Date?
    public var createdBefore: Date?
    public var sort: AssetSort?
    /// Opaque paging cursor from a previous result.
    public var cursor: String?
    public var limit: Int
    /// Facets to count (project, company, status, tag, source, kind, license, rights, model, orientation, month).
    public var facets: [String]

    public init(text: String? = nil, tags: [String] = [], excludeTags: [String] = [], projects: [String] = [],
                company: String? = nil, inbox: Bool = false, statuses: [ProjectStatus] = [],
                excludeStatuses: [ProjectStatus] = [], source: AssetSource? = nil, kind: AssetKind? = nil,
                licenseClass: LicenseClass? = nil, rightsClass: RightsClass? = nil, model: ModelID? = nil,
                capability: Capability? = nil, orientation: String? = nil, createdAfter: Date? = nil,
                createdBefore: Date? = nil, sort: AssetSort? = nil, cursor: String? = nil, limit: Int = 50,
                facets: [String] = []) {
        self.text = text
        self.tags = tags
        self.excludeTags = excludeTags
        self.projects = projects
        self.company = company
        self.inbox = inbox
        self.statuses = statuses
        self.excludeStatuses = excludeStatuses
        self.source = source
        self.kind = kind
        self.licenseClass = licenseClass
        self.rightsClass = rightsClass
        self.model = model
        self.capability = capability
        self.orientation = orientation
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.sort = sort
        self.cursor = cursor
        self.limit = limit
        self.facets = facets
    }

    enum CodingKeys: String, CodingKey {
        case text = "q"
        case tags
        case excludeTags = "exclude_tags"
        case projects, company, inbox, statuses
        case excludeStatuses = "exclude_statuses"
        case source, kind
        case licenseClass = "license_class"
        case rightsClass = "rights_class"
        case model, capability, orientation, collections, colour, expiry, described
        case createdAfter = "created_after"
        case createdBefore = "created_before"
        case sort, cursor, limit, facets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `q` may carry the query language; structured fields add to what it parses into.
        var base = try c.decodeIfPresent(String.self, forKey: .text).map(AssetQuery.parse) ?? AssetQuery()
        base.tags += try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        base.excludeTags += try c.decodeIfPresent([String].self, forKey: .excludeTags) ?? []
        base.projects += try c.decodeIfPresent([String].self, forKey: .projects) ?? []
        base.company = try c.decodeIfPresent(String.self, forKey: .company) ?? base.company
        base.inbox = try c.decodeIfPresent(Bool.self, forKey: .inbox) ?? base.inbox
        base.statuses += try c.decodeIfPresent([ProjectStatus].self, forKey: .statuses) ?? []
        base.excludeStatuses += try c.decodeIfPresent([ProjectStatus].self, forKey: .excludeStatuses) ?? []
        base.source = try c.decodeIfPresent(AssetSource.self, forKey: .source) ?? base.source
        base.kind = try c.decodeIfPresent(AssetKind.self, forKey: .kind) ?? base.kind
        base.licenseClass = try c.decodeIfPresent(LicenseClass.self, forKey: .licenseClass) ?? base.licenseClass
        base.rightsClass = try c.decodeIfPresent(RightsClass.self, forKey: .rightsClass) ?? base.rightsClass
        base.model = try c.decodeIfPresent(ModelID.self, forKey: .model) ?? base.model
        base.capability = try c.decodeIfPresent(Capability.self, forKey: .capability) ?? base.capability
        base.orientation = try c.decodeIfPresent(String.self, forKey: .orientation) ?? base.orientation
        base.collections += try c.decodeIfPresent([String].self, forKey: .collections) ?? []
        base.colour = try c.decodeIfPresent(String.self, forKey: .colour) ?? base.colour
        base.expiry = try c.decodeIfPresent(String.self, forKey: .expiry) ?? base.expiry
        base.described = try c.decodeIfPresent(Bool.self, forKey: .described) ?? base.described
        base.createdAfter = try c.decodeIfPresent(Date.self, forKey: .createdAfter) ?? base.createdAfter
        base.createdBefore = try c.decodeIfPresent(Date.self, forKey: .createdBefore) ?? base.createdBefore
        base.sort = try c.decodeIfPresent(AssetSort.self, forKey: .sort) ?? base.sort
        base.cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        base.limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50
        base.facets = try c.decodeIfPresent([String].self, forKey: .facets) ?? []
        self = base
    }

    /// Parses the query language:
    ///
    ///     hero "golden hour" project:acme/summer-launch usage:social -status:rejected orient:landscape after:2026-09
    ///
    /// Bare words and quoted phrases are full-text terms. `key:value` tokens with a reserved key become structured
    /// filters (project, company/client, status, tag, source, kind, license, rights, model, capability,
    /// orientation/orient, after, before, sort, is:inbox); any other `ns:value` is a namespaced tag. A leading `-`
    /// negates a tag or status.
    public static func parse(_ input: String) -> AssetQuery {
        var query = AssetQuery()
        var terms: [String] = []
        for raw in tokenize(input) {
            var token = raw
            let negated = token.hasPrefix("-") && token.count > 1
            if negated { token.removeFirst() }
            guard !token.hasPrefix("\""), let colon = token.firstIndex(of: ":"), colon != token.startIndex,
                  token.index(after: colon) != token.endIndex else {
                if !negated { terms.append(raw) }
                continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch key {
            case "project": query.projects.append(value)
            case "company", "client": query.company = value
            case "status":
                if let s = ProjectStatus(rawValue: value.lowercased()) {
                    if negated { query.excludeStatuses.append(s) } else { query.statuses.append(s) }
                }
            case "tag": if negated { query.excludeTags.append(value) } else { query.tags.append(value) }
            case "source": query.source = AssetSource(rawValue: value.lowercased())
            case "kind": query.kind = AssetKind(rawValue: value.lowercased())
            case "license": query.licenseClass = LicenseClass(rawValue: value)
            case "rights": query.rightsClass = RightsClass(rawValue: value.lowercased())
            case "model": query.model = ModelID(value)
            case "capability": query.capability = Capability(rawValue: value)
            case "orientation", "orient": query.orientation = value.lowercased()
            case "collection", "folder": query.collections.append(value)
            case "colour", "color": query.colour = value.lowercased()
            case "expires", "expiry": query.expiry = value.lowercased()
            case "after": query.createdAfter = parseDate(value)
            case "before": query.createdBefore = parseDate(value)
            case "sort": query.sort = AssetSort(rawValue: value.lowercased())
            case "is" where value.lowercased() == "inbox": query.inbox = true
            case "is" where value.lowercased() == "described": query.described = true
            case "is" where value.lowercased() == "undescribed": query.described = false
            default:
                let tag = "\(key):\(value)"
                if negated { query.excludeTags.append(tag) } else { query.tags.append(tag) }
            }
        }
        let text = terms.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        query.text = text.isEmpty ? nil : text
        return query
    }

    /// Splits on whitespace, keeping `"quoted phrases"` (and `key:"quoted value"`) whole.
    public static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in input {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// The query back in the search language — the inverse of `parse` for every filter it reads (paging and facets
    /// are not part of it). Smart collections show and edit their saved query as this text.
    public var languageString: String {
        func quoted(_ value: String) -> String { value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value }
        func token(_ key: String, _ value: String) -> String { "\(key):\(quoted(value))" }
        func day(_ date: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
        }
        var parts: [String] = []
        if let text { parts.append(text) }
        parts += projects.map { token("project", $0) }
        if let company { parts.append(token("client", company)) }
        parts += statuses.map { token("status", $0.rawValue) }
        parts += excludeStatuses.map { "-" + token("status", $0.rawValue) }
        parts += tags.map { $0.contains(":") ? quoted($0) : token("tag", $0) }
        parts += excludeTags.map { "-" + ($0.contains(":") ? quoted($0) : token("tag", $0)) }
        parts += collections.map { token("collection", $0) }
        if let source { parts.append(token("source", source.rawValue)) }
        if let kind { parts.append(token("kind", kind.rawValue)) }
        if let licenseClass { parts.append(token("license", licenseClass.rawValue)) }
        if let rightsClass { parts.append(token("rights", rightsClass.rawValue)) }
        if let model { parts.append(token("model", model.rawValue)) }
        if let capability { parts.append(token("capability", capability.rawValue)) }
        if let orientation { parts.append(token("orient", orientation)) }
        if let colour { parts.append(token("colour", colour)) }
        if let expiry { parts.append(token("expires", expiry)) }
        if let createdAfter { parts.append(token("after", day(createdAfter))) }
        if let createdBefore { parts.append(token("before", day(createdBefore))) }
        if let sort { parts.append(token("sort", sort.rawValue)) }
        if inbox { parts.append("is:inbox") }
        if let described { parts.append(described ? "is:described" : "is:undescribed") }
        return parts.joined(separator: " ")
    }

    /// `2026`, `2026-09`, `2026-09-15`, or ISO-8601.
    static func parseDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        if (1...3).contains(parts.count), value.count <= 10 {
            var c = DateComponents()
            c.calendar = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")
            c.year = parts[0]
            c.month = parts.count > 1 ? parts[1] : 1
            c.day = parts.count > 2 ? parts[2] : 1
            return c.date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
