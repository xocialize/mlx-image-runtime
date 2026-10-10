import Foundation

// Near-duplicates (Docs/CMS-ROADMAP.md, L2): find images that are the same picture — identical bytes, or a 64-bit
// perceptual hash within a few bits (a resize, a recompression, a re-export) — and resolve them by keeping one.

/// An asset that looks like another one.
public struct SimilarAsset: Sendable, Codable, Equatable {
    public var asset: AssetInfo
    /// Perceptual-hash distance in bits (0–64); 0 for identical bytes.
    public var distance: Int
    public var sameBytes: Bool
    /// A deliberate version, not an accidental copy: made from the other image by a job here (an upscale, a
    /// restore, an edit), or the image such a version was made from. Never suggested for the trash.
    public var isVersion: Bool

    public init(asset: AssetInfo, distance: Int, sameBytes: Bool, isVersion: Bool = false) {
        self.asset = asset
        self.distance = distance
        self.sameBytes = sameBytes
        self.isVersion = isVersion
    }

    enum CodingKeys: String, CodingKey {
        case asset, distance
        case sameBytes = "same_bytes"
        case isVersion = "is_version"
    }
}

/// Images that are the same picture, clustered transitively. `suggestedKeep` is the one to keep by default: one
/// filed in a project, then an original over a version, then the largest, then the oldest. `suggestedTrash` holds
/// only accidental copies (re-uploads, re-exports): versions made here are never suggested.
public struct DuplicateGroup: Sendable, Codable, Equatable, Identifiable {
    public var id: String { suggestedKeep.rawValue }
    public var suggestedKeep: AssetID
    public var suggestedTrash: [AssetID]
    /// Every member, the suggested keeper first; `distance` is measured from the keeper.
    public var members: [SimilarAsset]

    public init(suggestedKeep: AssetID, suggestedTrash: [AssetID], members: [SimilarAsset]) {
        self.suggestedKeep = suggestedKeep
        self.suggestedTrash = suggestedTrash
        self.members = members
    }

    enum CodingKeys: String, CodingKey {
        case suggestedKeep = "suggested_keep"
        case suggestedTrash = "suggested_trash"
        case members
    }
}

/// What resolving a duplicate group did.
public struct DuplicateResolution: Sendable, Codable, Equatable {
    public var kept: AssetID
    /// Moved to the trash (restorable for 30 days).
    public var trashed: [AssetID]
    /// Filing carried over to the keeper before trashing.
    public var mergedTags: Int
    public var mergedProjects: Int
    public var mergedCollections: Int
    /// Empty text fields on the keeper filled from the others (name, caption, alt text, credit…).
    public var filledFields: [String]

    public init(kept: AssetID, trashed: [AssetID], mergedTags: Int, mergedProjects: Int, mergedCollections: Int,
                filledFields: [String]) {
        self.kept = kept
        self.trashed = trashed
        self.mergedTags = mergedTags
        self.mergedProjects = mergedProjects
        self.mergedCollections = mergedCollections
        self.filledFields = filledFields
    }

    enum CodingKeys: String, CodingKey {
        case kept, trashed
        case mergedTags = "merged_tags"
        case mergedProjects = "merged_projects"
        case mergedCollections = "merged_collections"
        case filledFields = "filled_fields"
    }
}
