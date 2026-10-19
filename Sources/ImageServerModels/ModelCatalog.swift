import ForgeCore
import Foundation
import ImageServerAPI
import MLXServeCore
import MLXToolKit

/// One servable model: which package, which configuration, which public id, and the measured envelope it may be
/// asked to serve. A model is only visible on the wire once a catalog entry maps it, so a new Forge tier never
/// appears by accident.
public struct CatalogEntry: Sendable {
    public enum Source: Sendable {
        /// A package this app registers itself (as a ForgeCore `ExternalRegistration`).
        case package(manifest: PackageManifest, register: @Sendable (MLXServeEngine) async throws -> PackageID)
        /// A tier ForgeCore registers; resolved to its PackageID and manifest at bootstrap.
        case forge(ForgeModel)
    }

    public let id: ModelID
    /// For `.package` entries, the explicit engine id (`imgsrv.<id>`, AB-A-0109). For `.forge` entries, a
    /// placeholder until bootstrap resolves ForgeCore's id.
    public let packageID: PackageID
    public let displayName: String
    public let summary: String
    /// Capabilities exposed on the wire (may be a subset of what the package declares).
    public let capabilities: [Capability]
    /// Capabilities this entry is the preferred default route for (among permissive ∧ prod entries).
    public let preferredFor: Set<Capability>
    public let maturity: Maturity
    /// Default envelope: output size for generative capabilities, maximum input size for processing ones.
    public let envelope: SizeEnvelope
    /// Per-capability overrides (e.g. an edit capped below the model's text-to-image size).
    public let envelopes: [Capability: SizeEnvelope]
    public let defaults: GenerationDefaults
    public let quant: Quant?
    /// A local snapshot the entry loads from (no download involved). The engine's download check cannot see these.
    public let localSnapshot: String?
    /// The package `metaData` keys a request may set (`JobSpec.metaData`, AB-A-0191). Submit refuses any other.
    public let requestKeys: [RequestKey]
    public let source: Source

    public init(id: ModelID, packageID: PackageID? = nil, displayName: String, summary: String,
                capabilities: [Capability], preferredFor: Set<Capability> = [], maturity: Maturity,
                envelope: SizeEnvelope, envelopes: [Capability: SizeEnvelope] = [:], defaults: GenerationDefaults,
                quant: Quant? = nil, localSnapshot: String? = nil, requestKeys: [RequestKey] = [], source: Source) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.capabilities = capabilities
        self.preferredFor = preferredFor
        self.maturity = maturity
        self.envelope = envelope
        self.envelopes = envelopes
        self.defaults = defaults
        self.quant = quant
        self.localSnapshot = localSnapshot
        self.requestKeys = requestKeys
        self.source = source
        switch source {
        case .package: self.packageID = packageID ?? PackageID("imgsrv.\(id.rawValue)")
        case .forge(let model): self.packageID = PackageID("forge.\(model)")
        }
    }

    public func envelope(for capability: Capability) -> SizeEnvelope { envelopes[capability] ?? envelope }

    /// The manifest, for entries whose package this app registers (Forge tiers resolve theirs at bootstrap).
    public var manifest: PackageManifest? {
        if case .package(let manifest, _) = source { return manifest }
        return nil
    }

    public var forgeModel: ForgeModel? {
        if case .forge(let model) = source { return model }
        return nil
    }
}

/// The servable models, in routing order. Default routing (no model named) picks among permissive ∧ prod entries:
/// those preferring the capability first, then a resident one, then catalog order.
///
/// This target holds ForgeCore's tiers (`processing()`), which link no generative package. The generative and
/// analysis entries (`all()`, `generative()`, `analysis()`) live in `ImageServerCatalog`, so an app that embeds only
/// ForgeCore (Pixel Agency Desktop's built-in engine) never links Klein, Z-Image, Qwen and the rest.
///
/// Envelopes follow AB-L-0202: a package whose footprint was measured at 1024² is capped at 1024² area until a
/// larger size is measured. Processing-tier input caps are conservative (not yet measured per tier).
public enum ModelCatalog {
    /// Where local snapshots are looked up. Per model: `MLXIMG_SNAPSHOT_<ID>` (id upper-cased, dashes and dots →
    /// underscores); otherwise `MLXIMG_WEIGHTS_ROOT/<folder>` when that folder exists (the mlxengine-image layout).
    public struct Snapshots: Sendable {
        let environment: [String: String]

        public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            self.environment = environment
        }

        public func path(for id: String, folder: String? = nil) -> String? {
            let key = "MLXIMG_SNAPSHOT_" + id.uppercased().replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_")
            if let path = environment[key], !path.isEmpty { return path }
            guard let folder, let root = environment["MLXIMG_WEIGHTS_ROOT"], !root.isEmpty else { return nil }
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(folder).path
            return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
        }
    }

    public static func snapshotOverride(for id: ModelID, environment: [String: String]) -> String? {
        Snapshots(environment: environment).path(for: id.rawValue)
    }

    // MARK: - ForgeCore image-processing tiers

    /// ForgeCore registers these (one shared, weekly-moving tier table); the catalog only decides which are visible
    /// and under which public id. Input envelopes are conservative caps, not measured per tier yet.
    public static func processing() -> [CatalogEntry] {
        func tier(_ id: String, _ model: ForgeModel, _ capability: Capability, _ name: String, _ summary: String,
                  preferred: Bool = false, maxInput: Int = 4096 * 4096, maturity: Maturity = .prod) -> CatalogEntry {
            CatalogEntry(id: ModelID(id), displayName: name, summary: summary, capabilities: [capability],
                         preferredFor: preferred ? [capability] : [], maturity: maturity,
                         envelope: SizeEnvelope(maxPixels: maxInput, multipleOf: 1, maxInputs: 1),
                         defaults: GenerationDefaults(steps: nil, guidance: nil), source: .forge(model))
        }
        return [
            tier("nerve-upscale", .upscale, .imageUpscale, "NERVE upscale",
                 "Fast ×2/×4 super-resolution (Apache-2.0, CC0-trained). params.scale 2 or 4; 6 and 8 as chains.",
                 preferred: true, maxInput: 2048 * 2048),
            tier("realplksr-upscale", .upscaleFidelity, .imageUpscale, "RealPLKSR upscale",
                 "Fidelity ×4 super-resolution trained on Commons-SR (Apache-2.0).", maxInput: 2048 * 2048),
            tier("heart-upscale", .upscaleHEART, .imageUpscale, "HEART upscale",
                 "High-fidelity ×4 window-attention upscaler (Apache-2.0); slower.", maxInput: 1536 * 1536),
            tier("seedvr2-upscale", .upscaleQuality, .imageUpscale, "SeedVR2 upscale",
                 "Diffusion quality upscaler (SeedVR2-3B); heavy.", maxInput: 1024 * 1024),
            tier("nacre-upscale", .upscaleNacre, .imageUpscale, "Nacre upscale",
                 "Provenance-clean generative ×4 upscaler (Apache-2.0, Commons-trained), behind the text-legibility guard.",
                 maxInput: 1024 * 1024),
            tier("vosr2-upscale", .upscaleGenerative, .imageUpscale, "VOSR2 upscale",
                 "Generative ×4 stills upscaler (Apache-2.0 DiT), behind the text-legibility guard (AB-D-0111). Stills only.",
                 maxInput: 1024 * 1024),
            tier("anime4k-upscale", .upscaleInstant, .imageUpscale, "Anime4K VL",
                 "Instant, model-free ×2 upscaler on Metal shaders (MIT, nothing to download); ×4/×8 by doubling, ×6 fitted "
                 + "from ×8. The efficient choice, not a quality rival to the learned tiers (AB-D-0146).",
                 maxInput: 2048 * 2048),
            tier("nafnet-restore", .restore, .imageRestore, "NAFNet restore",
                 "Conservative general restoration (denoise/deblur).", preferred: true),
            tier("restormer-motion", .restormerMotion, .imageRestore, "Restormer motion deblur", "Motion-blur removal."),
            tier("restormer-defocus", .restormerDefocus, .imageRestore, "Restormer defocus deblur", "Defocus-blur removal."),
            tier("restormer-denoise", .restormerDenoise, .imageRestore, "Restormer denoise", "Real-noise denoising."),
            tier("drunet-denoise", .denoiseStrength, .imageRestore, "DRUNet denoise",
                 "Denoising with a strength dial (params.strength)."),
            tier("scunet-denoise", .denoiseBlind, .imageRestore, "SCUNet denoise", "Strong blind denoising."),
            tier("gfpgan-face", .faceRestore, .imageRestore, "GFPGAN face restore", "Face restoration (GFPGAN v1.4)."),
            tier("restoreformer-face", .faceRestoreVQ, .imageRestore, "RestoreFormer++ face restore",
                 "Face restoration with a VQ dictionary."),
            tier("cidnet-relight", .relight, .imageRelight, "HVI-CIDNet relight",
                 "Exposure correction for under/over-exposed images (params.strength).", preferred: true),
            tier("ddcolor-colorize", .colorize, .imageColorize, "DDColor colorize",
                 "Colorizes black-and-white photos.", preferred: true),
            tier("lama-inpaint", .inpaint, .imageInpaint, "LaMa inpaint",
                 "Removes the masked region and fills it plausibly (inputs.image + inputs.mask, white = remove).",
                 preferred: true, maxInput: 2048 * 2048),
            tier("birefnet-matte", .matte, .matting, "BiRefNet matte",
                 "Foreground matte / background removal; returns an alpha matte asset.", preferred: true),
            tier("edgetam-segment", .promptMask, .promptSegment, "EdgeTAM segment",
                 "Segments the object at the given points/box; returns a matte and score.", preferred: true),
            tier("sam21-segment", .promptMaskQuality, .promptSegment, "SAM 2.1 segment",
                 "Higher-quality promptable segmentation."),
            tier("bopbtl-defects", .defectDetect, .defectDetect, "BOPBTL defect detection",
                 "Finds scratches/dust/tears on old photos; returns a mask (feed it to imageInpaint).", preferred: true),
            tier("siglip2-quality", .qualityScore, .imageQualityScore, "SigLIP2 quality score",
                 "No-reference image quality score (higher is better).", preferred: true),
        ]
    }
}
