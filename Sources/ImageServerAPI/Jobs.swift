import Foundation
import MLXToolKit

/// Where a job's outputs are filed in the library. `project` is resolved to an id and frozen at submit.
public struct FileSpec: Sendable, Codable, Equatable {
    /// Project reference: id, slug, or `company/slug`.
    public var project: String?
    public var status: ProjectStatus?
    public var role: String?
    public var tags: [String]

    public init(project: String? = nil, status: ProjectStatus? = nil, role: String? = nil, tags: [String] = []) {
        self.project = project
        self.status = status
        self.role = role
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

public enum JobKind: String, Sendable, Codable {
    /// Run the capability and store outputs.
    case generate
    /// Download and load the model only ("warm"). Goes through the queue so it never competes with a running job.
    case prepare
    /// imageAnalysis on one library asset, written back to it as caption, alt text and auto tags.
    case describe
}

/// What a caller asked for. Stored verbatim in the ledger (`spec_json`) — engine requests are not `Codable`, so the
/// scheduler re-derives the typed request from this on every attempt, including after a relaunch.
public struct JobSpec: Sendable, Codable, Equatable {
    public var kind: JobKind = .generate
    public var capability: Capability
    /// nil = default routing (permissive ∧ prod only).
    public var model: ModelID?
    public var mode: String?
    /// Canonical capability parameters (`prompt`, `width`, `steps`, …). camelCase or snake_case keys both resolve.
    public var params: JSONObject
    /// Named image inputs, already resolved to library assets (bytes never ride the spec).
    public var inputs: [String: [AssetID]]
    /// Number of outputs; output i uses seed `seed + i`.
    public var count: Int
    public var outputFormat: OutputFormat
    public var tags: [String]
    /// Client-requested priority in -1…1 (the scheduler adds its own UI boost on top).
    public var priority: Int
    /// Library filing for the outputs (project, status, extra tags).
    public var file: FileSpec?
    /// Brand kit: `company/kit[@revision]`, a `bk_` id, or `none`. Omitted = the filing project's kit, else the
    /// company default.
    public var brand: String?
    /// Which brand aspects to apply; nil = `auto` (all that fit the capability), [] = `none`.
    public var brandApply: [BrandAspect]?
    /// Set by the server at submit: what the brand did, frozen like the licence stamp.
    public var brandApplied: BrandApplication?

    public init(kind: JobKind = .generate, capability: Capability, model: ModelID? = nil, mode: String? = nil,
                params: JSONObject = [:], inputs: [String: [AssetID]] = [:], count: Int = 1,
                outputFormat: OutputFormat = .png, tags: [String] = [], priority: Int = 0, file: FileSpec? = nil) {
        self.file = file
        self.kind = kind
        self.capability = capability
        self.model = model
        self.mode = mode
        self.params = params
        self.inputs = inputs
        self.count = count
        self.outputFormat = outputFormat
        self.tags = tags
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case kind, capability, model, mode, params, inputs
        case count = "n"
        case outputFormat = "output_format"
        case tags, priority, file, brand
        case brandApply = "brand_apply"
        case brandApplied = "brand_applied"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(JobKind.self, forKey: .kind) ?? .generate
        capability = try c.decode(Capability.self, forKey: .capability)
        model = try c.decodeIfPresent(ModelID.self, forKey: .model)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        params = try c.decodeIfPresent(JSONObject.self, forKey: .params) ?? [:]
        // Each input is an image reference string (asset://…, ast_…, a data: URL or base64 — the HTTP layer resolves
        // non-asset forms to library assets before submit) or an array of them.
        if let raw = try c.decodeIfPresent([String: OneOrMany].self, forKey: .inputs) {
            inputs = raw.mapValues { $0.values.map { AssetID(uri: $0) ?? AssetID(rawValue: $0) } }
        } else {
            inputs = [:]
        }
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        outputFormat = try c.decodeIfPresent(OutputFormat.self, forKey: .outputFormat) ?? .png
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        file = try c.decodeIfPresent(FileSpec.self, forKey: .file)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        if let word = try? c.decodeIfPresent(String.self, forKey: .brandApply) {
            brandApply = word == "none" ? [] : nil
        } else {
            brandApply = try c.decodeIfPresent([BrandAspect].self, forKey: .brandApply)
        }
        brandApplied = try c.decodeIfPresent(BrandApplication.self, forKey: .brandApplied)
    }

    /// A parameter as the run sees it: the caller's value, else the brand's.
    public func effectiveParam(_ camelName: String) -> JSONValue? {
        if let own = param(camelName) { return own }
        guard let brand = brandApplied?.params else { return nil }
        let snake = camelName.reduce(into: "") { out, ch in
            if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
        }
        return brand[camelName] ?? brand[snake]
    }

    /// Parameter lookup that accepts both `negativePrompt` and `negative_prompt`.
    public func param(_ camelName: String) -> JSONValue? {
        if let v = params[camelName], v != .null { return v }
        let snake = camelName.reduce(into: "") { out, ch in
            if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
        }
        if let v = params[snake], v != .null { return v }
        return nil
    }
}

/// A JSON value that is either one string or an array of strings.
struct OneOrMany: Decodable {
    var values: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(String.self) { values = [one] } else { values = try c.decode([String].self) }
    }
}

public enum OutputFormat: String, Sendable, Codable, CaseIterable {
    case png, jpeg

    public var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// Where a job came from. The console gets a small scheduling boost; everything else is equal.
public enum JobOrigin: String, Sendable, Codable {
    case ui, rest, openai, mcp, cli
}

public enum JobState: String, Sendable, Codable, CaseIterable {
    case queued
    /// Chosen by the scheduler; waiting for memory or the engine.
    case admitted
    /// Downloading and/or loading weights.
    case preparing
    case running
    /// Encoding and storing outputs.
    case finishing
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
    public var isActive: Bool { self == .admitted || self == .preparing || self == .running || self == .finishing }
}

public struct JobProgress: Sendable, Codable, Equatable {
    /// `queued`, `waiting_for_memory`, `downloading`, `loading`, an engine run phase (`encode`, `denoise`,
    /// `decode`, …), or `storing`.
    public var phase: String
    /// 0…1 within the phase when known (downloads; step / totalSteps).
    public var fraction: Double?
    public var step: Int?
    public var totalSteps: Int?
    public var stage: Int?
    public var totalStages: Int?
    public var bytesPerSecond: Double?
    /// Which output (of `n`) is being produced, 0-based.
    public var outputIndex: Int?

    public init(phase: String, fraction: Double? = nil, step: Int? = nil, totalSteps: Int? = nil,
                stage: Int? = nil, totalStages: Int? = nil, bytesPerSecond: Double? = nil, outputIndex: Int? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.step = step
        self.totalSteps = totalSteps
        self.stage = stage
        self.totalStages = totalStages
        self.bytesPerSecond = bytesPerSecond
        self.outputIndex = outputIndex
    }

    enum CodingKeys: String, CodingKey {
        case phase, fraction, step
        case totalSteps = "total_steps"
        case stage
        case totalStages = "total_stages"
        case bytesPerSecond = "bytes_per_second"
        case outputIndex = "output_index"
    }

    /// One line for MCP progress messages and the menu bar, e.g. `denoise 5/8`.
    public var summary: String {
        var s = phase.replacingOccurrences(of: "_", with: " ")
        if let step, let totalSteps { s += " \(step)/\(totalSteps)" }
        else if let fraction { s += " \(Int((fraction * 100).rounded()))%" }
        if let stage, let totalStages, totalStages > 1 { s += ", stage \(stage)/\(totalStages)" }
        return s
    }
}

/// A job failure in API shape. `code` is stable (clients branch on it); `message` is for people.
public struct JobError: Sendable, Codable, Equatable, Error {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// The full public view of one job.
public struct JobSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var id: JobID
    public var state: JobState
    public var spec: JobSpec
    public var origin: JobOrigin
    public var client: ClientID
    /// The model the router chose (or the caller named).
    public var model: ModelID?
    public var license: LicenseStamp?
    /// 1-based position among queued jobs; nil once dispatched.
    public var queuePosition: Int?
    public var progress: JobProgress?
    public var outputs: [AssetID]
    /// Non-image results (e.g. `score`/`subscores` for imageQualityScore, `score` for promptSegment).
    public var result: JSONObject?
    /// Things the caller should know that did not stop the job (cross-client inputs, expiring rights, skipped brand
    /// preferences).
    public var warnings: [String]?
    public var error: JobError?
    public var seed: UInt64?
    public var width: Int?
    public var height: Int?
    public var attempt: Int
    public var enqueuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: JobID, state: JobState, spec: JobSpec, origin: JobOrigin, client: ClientID, model: ModelID?,
                license: LicenseStamp?, queuePosition: Int? = nil, progress: JobProgress? = nil,
                outputs: [AssetID] = [], error: JobError? = nil, seed: UInt64? = nil, width: Int? = nil,
                height: Int? = nil, attempt: Int = 0, enqueuedAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.state = state
        self.spec = spec
        self.origin = origin
        self.client = client
        self.model = model
        self.license = license
        self.queuePosition = queuePosition
        self.progress = progress
        self.outputs = outputs
        self.error = error
        self.seed = seed
        self.width = width
        self.height = height
        self.attempt = attempt
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, state, spec, origin, client, model, license
        case queuePosition = "queue_position"
        case progress, outputs, result, warnings, error, seed, width, height, attempt
        case enqueuedAt = "enqueued_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

/// What `submit` would do with a spec: the dry run behind `POST /v1/jobs/preview` and brand-kit previews.
public struct JobPreview: Sendable, Codable, Equatable {
    /// The spec as it would be queued (filing resolved, brand frozen, brand references appended to inputs).
    public var spec: JobSpec
    public var model: ModelID
    public var license: LicenseStamp
    /// The seed this preview drew (a real submit draws its own unless the caller passes one).
    public var seed: UInt64?
    public var width: Int?
    public var height: Int?
    public var brand: BrandApplication?
    public var warnings: [String]

    public init(spec: JobSpec, model: ModelID, license: LicenseStamp, seed: UInt64?, width: Int?, height: Int?,
                brand: BrandApplication?, warnings: [String]) {
        self.spec = spec
        self.model = model
        self.license = license
        self.seed = seed
        self.width = width
        self.height = height
        self.brand = brand
        self.warnings = warnings
    }
}

/// One change to one job. Every event carries the full snapshot, so a client that misses events loses nothing.
public struct JobEvent: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case enqueued
        case position
        case state
        case progress
        case finished
    }

    /// Monotonic per server process; SSE uses it as the event id.
    public var sequence: UInt64
    public var kind: Kind
    public var job: JobSnapshot

    public init(sequence: UInt64, kind: Kind, job: JobSnapshot) {
        self.sequence = sequence
        self.kind = kind
        self.job = job
    }
}

public enum CancelOutcome: String, Sendable, Codable {
    /// Was queued; removed before the engine saw it.
    case removed
    /// Was in flight; the cancel has been delivered to the run.
    case cancelling
    /// Already storing outputs — it will finish.
    case tooLate = "too_late"
    /// Already terminal.
    case terminal
    case notFound = "not_found"
}

public struct QueueStatus: Sendable, Codable, Equatable {
    public var running: JobSnapshot?
    public var queued: [JobSnapshot]
    public var residentModels: [ModelID]
    public var paused: Bool
    /// Assets waiting to be described (fed to the queue a few at a time).
    public var describeBacklog: Int

    public init(running: JobSnapshot?, queued: [JobSnapshot], residentModels: [ModelID], paused: Bool,
                describeBacklog: Int = 0) {
        self.running = running
        self.queued = queued
        self.residentModels = residentModels
        self.paused = paused
        self.describeBacklog = describeBacklog
    }

    enum CodingKeys: String, CodingKey {
        case running, queued
        case residentModels = "resident_models"
        case paused
        case describeBacklog = "describe_backlog"
    }
}
