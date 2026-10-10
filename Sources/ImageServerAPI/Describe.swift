import Foundation
import MLXToolKit

// Auto-describe (Docs/CMS-ROADMAP.md, L2): a vision model writes a caption, alt text and tags for an asset, as a
// low-priority `describe` job. What it wrote, and which model and licence wrote it, is kept with the asset; it fills
// empty fields and replaces only earlier auto tags, never what a person typed (unless `overwrite`).

/// The latest description a vision model wrote for an asset.
public struct AssetDescription: Sendable, Codable, Equatable {
    public var model: ModelID
    public var licenseClass: LicenseClass
    public var caption: String?
    public var altText: String?
    public var tags: [String]
    public var jobID: JobID?
    public var createdAt: Date

    public init(model: ModelID, licenseClass: LicenseClass, caption: String?, altText: String?, tags: [String],
                jobID: JobID?, createdAt: Date) {
        self.model = model
        self.licenseClass = licenseClass
        self.caption = caption
        self.altText = altText
        self.tags = tags
        self.jobID = jobID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case model
        case licenseClass = "license_class"
        case caption
        case altText = "alt_text"
        case tags
        case jobID = "job_id"
        case createdAt = "created_at"
    }
}

/// When the server describes new images by itself. Off by default: each description costs GPU time, and the first
/// one a model load.
public struct AutoDescribeSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    /// The analysis model; nil = default routing (permissive ∧ prod only).
    public var model: ModelID?
    /// Describe images people and agents upload.
    public var onUpload: Bool
    /// Describe generated and derived outputs too.
    public var onGenerate: Bool

    public init(enabled: Bool = false, model: ModelID? = nil, onUpload: Bool = true, onGenerate: Bool = false) {
        self.enabled = enabled
        self.model = model
        self.onUpload = onUpload
        self.onGenerate = onGenerate
    }

    enum CodingKeys: String, CodingKey {
        case enabled, model
        case onUpload = "on_upload"
        case onGenerate = "on_generate"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        model = try c.decodeIfPresent(ModelID.self, forKey: .model)
        onUpload = try c.decodeIfPresent(Bool.self, forKey: .onUpload) ?? true
        onGenerate = try c.decodeIfPresent(Bool.self, forKey: .onGenerate) ?? false
    }
}

public enum DescribeTrigger: String, Sendable, Codable {
    case upload, generate
}

public struct DescribeOptions: Sendable, Codable, Equatable {
    /// nil = the auto-describe model, else default routing.
    public var model: ModelID?
    /// Replace a caption / alt text a person wrote (auto tags are always replaced).
    public var overwrite: Bool

    public init(model: ModelID? = nil, overwrite: Bool = false) {
        self.model = model
        self.overwrite = overwrite
    }
}

/// What a describe request did: jobs queued now, assets waiting in the backlog (fed to the queue a few at a time),
/// and assets skipped with the reason.
public struct DescribeBatch: Sendable, Codable, Equatable {
    public var jobs: [JobSnapshot]
    public var backlog: Int
    public var skipped: [String: String]

    public init(jobs: [JobSnapshot], backlog: Int, skipped: [String: String]) {
        self.jobs = jobs
        self.backlog = backlog
        self.skipped = skipped
    }
}
