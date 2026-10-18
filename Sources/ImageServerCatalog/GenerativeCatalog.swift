import ForgeCore
import Foundation
import ImageServerAPI
import ImageServerModels
import MLXAnima
import MLXBoogu
import MLXKlein
import MLXMageFlow
import MLXMingImage
import MLXQwenImage21
import MLXMageVL
import MLXFlux3Klein
import MLXMossImage
import MossImage
import MLXQwenImageEdit
import MLXQwenImageFlash
import MLXSenseNovaU1
import MLXServeCore
import MLXToolKit
import MLXZImage

/// The generative and analysis packages this app registers itself, beside ForgeCore's tiers (`processing()`, in
/// ImageServerModels). Linking this target links every generative package.
extension ModelCatalog {
    /// Everything the server exposes: generative packages, then ForgeCore's image-processing tiers.
    public static func all(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CatalogEntry] {
        generative(environment: environment) + analysis() + processing()
    }

    // MARK: - Image understanding

    /// imageAnalysis models: visual Q&A, and the captions / alt text / tags auto-describe writes.
    public static func analysis() -> [CatalogEntry] { [mageVL()] }

    static func mageVL() -> CatalogEntry {
        let packageID = PackageID("imgsrv.mage-vl")
        // int8: greedy output byte-identical to bf16 and the PyTorch reference (48/48), 5.37 GB floor vs 9.51 GB.
        let configuration = MageVLConfiguration(quant: .int8)
        return CatalogEntry(
            id: "mage-vl", packageID: packageID, displayName: "Mage-VL",
            summary: "Microsoft Mage-VL 4B (Apache-2.0) — image understanding: captions, alt text, tags and visual "
                + "questions. int8, ~5.4 GB resident; the processor fits any input under its own pixel cap.",
            capabilities: [.imageAnalysis], preferredFor: [.imageAnalysis], maturity: .prod,
            // The package resizes inputs to its own cap, so the input envelope is only a sanity bound.
            envelope: SizeEnvelope(maxPixels: 100_000_000, multipleOf: 1, maxInputs: 1),
            defaults: GenerationDefaults(steps: nil, guidance: nil), quant: .int8,
            source: .package(manifest: MageVLPackage.manifest, register: {
                try await $0.register(MageVLPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    public static func generative(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CatalogEntry] {
        let snapshots = Snapshots(environment: environment)
        let mageFilter = mageContentFilter(environment)
        let residency = mageResidency(environment)
        var entries: [CatalogEntry] = [
            zImageTurbo(snapshots), kleinTurbo(), zImage(snapshots), kleinBase(), qwenImageFlash(), qwenImageEdit(),
            mageFlow(.flow, id: "mage-flow", name: "Mage-Flow", filter: mageFilter),
            mageFlow(.turbo, id: "mage-flow-turbo", name: "Mage-Flow Turbo", filter: mageFilter),
            mageFlowEdit(.edit, id: "mage-flow-edit", name: "Mage-Flow Edit", filter: mageFilter, residency: residency),
            mageFlowEdit(.editTurbo, id: "mage-flow-edit-turbo", name: "Mage-Flow Edit Turbo", filter: mageFilter,
                         residency: residency),
            mageFlowEdit(.editBase, id: "mage-flow-edit-base", name: "Mage-Flow Edit Base", filter: mageFilter,
                         residency: residency),
            senseNova(.q8, id: "sensenova-u1", name: "SenseNova-U1.5"),
            senseNova(.fast8V2, id: "sensenova-u1-fast", name: "SenseNova-U1.5 8-step"),
            senseNova(.fast8, id: "sensenova-u1-fast-v1", name: "SenseNova-U1.5 8-step (V1 adapter)"),
            moss(.sft, snapshots, quant: mossQuant(environment), textEncoderQuant: mossTextEncoderQuant(environment)),
            moss(.base, snapshots, quant: mossQuant(environment), textEncoderQuant: mossTextEncoderQuant(environment)),
            ming(),
        ]
        // Local-weights-only packages register only when their weights are present.
        if let boogu = boogu(snapshots) { entries.append(boogu) }
        if let booguEdit = booguEdit(snapshots) { entries.append(booguEdit) }
        if let anima = anima(snapshots) { entries.append(anima) }
        // Qwen-Image-2.1: naming it serves the Turbo checkpoint; the 40-step original is `qwen-image-2.1-base`.
        entries.append(qwenImage21Turbo(snapshots))
        entries.append(qwenImage21Base(snapshots))
        // FLUX 3 Image Klein: FLUX Kommunity licence → restricted, named-only (AB-D-0151).
        entries.append(flux3Klein(snapshots, quant: flux3Quant(environment)))
        return entries
    }

    // MARK: - Production generative

    static func zImageTurbo(_ snapshots: Snapshots) -> CatalogEntry {
        let packageID = PackageID("imgsrv.z-image-turbo")
        let snapshot = snapshots.path(for: "z-image-turbo", folder: "Z-Image-Turbo")
        let quant: Quant = snapshot == nil ? .int4 : .bf16
        let configuration = ZImageConfiguration.turbo(quant: quant, snapshotPath: snapshot)
        return CatalogEntry(
            id: "z-image-turbo", packageID: packageID, displayName: "Z-Image Turbo",
            summary: "Tongyi-MAI Z-Image Turbo 6B — distilled 8-step text-to-image, photoreal, EN/CN text rendering; "
                + "imageEdit is image-to-image re-generation (params.strength 0–1, default 0.75).",
            capabilities: [.textToImage, .imageEdit], preferredFor: [.textToImage], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: ZImageT2IPackage.maxOutputPixels, multipleOf: 16),
            defaults: GenerationDefaults(steps: 8, guidance: 0.0), quant: quant, localSnapshot: snapshot,
            source: .package(manifest: ZImageTurboT2IPackage.manifest, register: {
                try await $0.register(ZImageTurboT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    static func zImage(_ snapshots: Snapshots) -> CatalogEntry {
        let packageID = PackageID("imgsrv.z-image")
        let snapshot = snapshots.path(for: "z-image", folder: "Z-Image")
        let quant: Quant = snapshot == nil ? .int4 : .bf16
        let configuration = ZImageConfiguration.base(quant: quant, snapshotPath: snapshot)
        return CatalogEntry(
            id: "z-image", packageID: packageID, displayName: "Z-Image",
            summary: "Tongyi-MAI Z-Image 6B base — ~28-step CFG text-to-image, honours negative prompts.",
            capabilities: [.textToImage], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: ZImageT2IPackage.maxOutputPixels, multipleOf: 16),
            defaults: GenerationDefaults(steps: 28, guidance: 4.0), quant: quant, localSnapshot: snapshot,
            source: .package(manifest: ZImageT2IPackage.manifest, register: {
                try await $0.register(ZImageT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    static func kleinTurbo() -> CatalogEntry {
        let packageID = PackageID("imgsrv.klein-4b")
        let configuration = KleinConfiguration.turbo(quant: .bf16)
        return CatalogEntry(
            id: "klein-4b", packageID: packageID, displayName: "FLUX.2 Klein 4B",
            summary: "Black Forest Labs FLUX.2 [klein] 4B (Apache-2.0) — distilled 4-step text-to-image and multi-reference "
                + "instruction editing (up to 4 reference images); fast, strong prompt adherence.",
            capabilities: [.textToImage, .imageEdit], preferredFor: [.imageEdit], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, maxInputs: 4),
            defaults: GenerationDefaults(steps: 4, guidance: 1.0), quant: .bf16,
            source: .package(manifest: Klein4BT2IPackage.manifest, register: {
                try await $0.register(Klein4BT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    static func kleinBase() -> CatalogEntry {
        let packageID = PackageID("imgsrv.klein-4b-base")
        let configuration = KleinConfiguration.base(quant: .bf16)
        return CatalogEntry(
            id: "klein-4b-base", packageID: packageID, displayName: "FLUX.2 Klein 4B Base",
            summary: "FLUX.2 [klein] 4B base (Apache-2.0) — 28-step CFG quality tier for text-to-image and editing; "
                + "honours negative prompts.",
            capabilities: [.textToImage, .imageEdit], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, maxInputs: 4),
            defaults: GenerationDefaults(steps: 28, guidance: 4.0), quant: .bf16,
            source: .package(manifest: Klein4BBaseT2IPackage.manifest, register: {
                try await $0.register(Klein4BBaseT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    static func qwenImageFlash() -> CatalogEntry {
        let packageID = PackageID("imgsrv.qwen-image-flash")
        let configuration = QwenImageFlashConfiguration(quant: .int8)
        return CatalogEntry(
            id: "qwen-image-flash", packageID: packageID, displayName: "Qwen-Image Flash",
            summary: "Qwen-Image distilled 4-step text-to-image (NVIDIA Open Model weights) — strong text rendering and layout.",
            capabilities: [.textToImage], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16),
            defaults: GenerationDefaults(steps: 4, guidance: 1.0), quant: .int8,
            source: .package(manifest: QwenImageFlashPackage.manifest, register: {
                try await $0.register(QwenImageFlashPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// Qwen-Image-Edit-2511: the strongest instruction editor in the collection, and the heaviest (~42 GB bf16).
    /// Output area is fixed near 1024² at the first input's aspect — request width/height are ignored.
    static func qwenImageEdit() -> CatalogEntry {
        let packageID = PackageID("imgsrv.qwen-image-edit")
        let configuration = QwenImageEditConfiguration()
        return CatalogEntry(
            id: "qwen-image-edit", packageID: packageID, displayName: "Qwen-Image-Edit 2511",
            summary: "Qwen-Image-Edit-2511 20B (Apache-2.0) — high-fidelity instruction editing with up to 3 reference "
                + "images; output ≈1024² area at the input's aspect. Heavy: ~42 GB resident.",
            capabilities: [.imageEdit], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 32, maxInputs: 3),
            defaults: GenerationDefaults(steps: 20, guidance: 4.0), quant: .bf16,
            source: .package(manifest: QwenImageEditPackage.manifest, register: {
                try await $0.register(QwenImageEditPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// Microsoft's content filter on Mage-Flow (its Responsible-AI screen) is off unless `MLXIMG_MAGE_CONTENT_FILTER` is
    /// `1`, `on` or `true` (AB-D-0122). It refused benign photos in the removal gate, and on a 4-step edit it is the
    /// slowest stage (~4 s). With it on, a refusal fails the job with the filter's verdict.
    public static func mageContentFilter(_ environment: [String: String]) -> Bool {
        ["1", "on", "true"].contains(environment["MLXIMG_MAGE_CONTENT_FILTER"]?.lowercased() ?? "")
    }

    static func mageFilterNote(_ filter: Bool) -> String { filter ? " Content filter on (fail-closed)." : "" }

    /// How Mage-Flow-Edit holds its two big models on this Mac (the creative upscale's small-Mac path, AB-D-0126).
    public enum MageResidency: String, Sendable, CaseIterable {
        /// Conditioner and DiT stay loaded: about 17 GB at the peak (int8 Turbo).
        case resident
        /// The Qwen3-VL conditioner leaves after each encode: about 15 GB at the peak.
        case evictConditioner = "evict-conditioner"
        /// The conditioner and the DiT take turns and neither stays between requests: about 10 GB at the peak, one load
        /// of each per request — the `tiles` mode makes that one per creative upscale, not one per tile.
        case evictAll = "evict-all"
    }

    /// Below 32 GB the models take turns (`evictAll`); from 32 GB they stay resident. `MLXIMG_MAGE_RESIDENCY`
    /// (`resident`, `evict-conditioner`, `evict-all`) overrides it, for a Mac shared with other work or to measure.
    public static func mageResidency(_ environment: [String: String],
                                     physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MageResidency {
        if let raw = environment["MLXIMG_MAGE_RESIDENCY"]?.lowercased(), let chosen = MageResidency(rawValue: raw) { return chosen }
        return physicalMemory < 32 << 30 ? .evictAll : .resident
    }

    /// Mage-Flow (MIT weights and port, mage-flow-swift ≥ 0.9.1) is prod: offered by default, preferred for nothing.
    static func mageFlow(_ variant: MageFlowVariant, id: String, name: String, filter: Bool) -> CatalogEntry {
        let packageID = PackageID("imgsrv.\(id)")
        let configuration = MageFlowConfiguration(variant: variant, quant: .bf16, bypassContentFilter: !filter)
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name,
            summary: "\(name) (MIT) — square text-to-image." + mageFilterNote(filter),
            capabilities: [.textToImage], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, requiresSquare: true),
            defaults: GenerationDefaults(steps: variant.defaultSteps, guidance: Double(variant.defaultGuidance)),
            quant: .bf16,
            source: .package(manifest: MageFlowT2IPackage.manifest, register: {
                try await $0.register(MageFlowT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// The edit checkpoints: RL-aligned (`.edit`, 20 steps), distilled Turbo (4 steps) and Base (30 steps). Turbo and
    /// Base are the removal gate's named route (AB-R-0464) and the Image Engine's erase tier (AB-T-0220). Turbo runs its
    /// int8 DiT, as the gate measured it (3.5 s at 1024², 5.6 GB DiT instead of 7.7).
    /// Mage-Flow-Edit (mage-flow-swift ≥ 0.11.0): the `tiles` mode edits N images in one request with one conditioner
    /// load, and `residency` sets which models stay loaded (`mageResidency`).
    static func mageFlowEdit(_ variant: MageFlowVariant, id: String, name: String, filter: Bool,
                             residency: MageResidency = .resident) -> CatalogEntry {
        let packageID = PackageID("imgsrv.\(id)")
        let quant: Quant = variant == .editTurbo ? .int8 : .bf16
        let configuration = MageFlowConfiguration(variant: variant, quant: quant,
                                                  evictConditioner: residency == .evictConditioner,
                                                  evictTransformer: residency == .evictAll, bypassContentFilter: !filter)
        let tier = variant == .editTurbo ? " Distilled, 4 steps, int8." : variant == .editBase ? " Quality tier, 30 steps." : ""
        let turns = residency == .resident ? "" : " Conditioner and DiT load per request (small-Mac residency)."
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name,
            summary: "\(name) (MIT) — square instruction editing with up to 3 references; the tiles mode edits many "
                + "images at once." + tier + turns + mageFilterNote(filter),
            capabilities: [.imageEdit], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, maxInputs: 3, requiresSquare: true),
            defaults: GenerationDefaults(steps: variant.defaultSteps, guidance: Double(variant.defaultGuidance)),
            quant: quant,
            source: .package(manifest: MageFlowEditPackage.manifest, register: {
                try await $0.register(MageFlowEditPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    // MARK: - Work in progress generative (named use only)

    /// SenseNova-U1.5 (sensenova-u1-swift ≥ 0.5.1, PROD since 2026-10-11, AB-R-0493). Every tier
    /// serves T2I and instruction editing: the 8-step distill adapters touch only the generation
    /// stream, and their 8-step cfg-1 edit matches the 50-step base edit (AB-R-0492). The fast
    /// entry rides the V2 adapter — upstream's recommended one, which removes the V1 adapter's
    /// shadow/highlight clipping and over-sharpening at fixed seed (AB-R-0490); the V1 tier stays
    /// reachable by name so existing seeds keep reproducing. Prod and permissive (Apache-2.0
    /// weights, MIT port), preferred for nothing: Z-Image Turbo / Klein keep the defaults.
    static func senseNova(_ variant: SenseNovaVariant, id: String, name: String) -> CatalogEntry {
        let packageID = PackageID("imgsrv.\(id)")
        let configuration = SenseNovaU1Configuration(variant: variant)
        let distilled = variant.isDistilled
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name,
            summary: "SenseNova-U1.5 8B MoT (Apache-2.0) — unified understanding + generation; sizes in multiples of 32"
                + (distilled ? "; distilled 8-step, cfg-free, also instruction editing." : "; also instruction editing."),
            // imageAnalysis: the same resident model answers visual questions on every tier (the
            // distill adapters leave the understanding stream untouched) — named use only; Mage-VL
            // stays the preferred analysis tier at a quarter of the footprint.
            capabilities: [.textToImage, .imageEdit, .imageAnalysis], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 2048 * 2048, multipleOf: 32, maxInputs: 1),
            defaults: GenerationDefaults(steps: distilled ? 8 : 50, guidance: distilled ? 1.0 : 4.0),
            quant: variant == .bf16 ? .bf16 : (variant == .fast4 ? .int4 : .int8),
            source: .package(manifest: SenseNovaU1Package.manifest, register: {
                try await $0.register(SenseNovaU1Package.registration, configuration: configuration, id: packageID)
            }))
    }

    /// MOSS-Image's DiT tier on this Mac: bf16 from 48 GB (10.4 GB resident), int8 below it (5.8 GB). In-app peaks
    /// (AB-D-0152): with `mossTextEncoderQuant` that is bf16/bf16 from 48 GB (26.5 GB), int8/int8 below it (15.7 GB),
    /// the per-request encode at every size up to the 1456² cap since moss-image-swift 0.3.0's row-band VAE decode.
    /// The 48 GB line was set when the untiled decode put a bf16 DiT at 27.3 GB at the cap; bf16 DiT + int8 encoder now
    /// peaks at 20.4 GB. Text error is within noise of bf16/bf16 (OCR gate, AB-R-0572). `MLXIMG_MOSS_QUANT` (`bf16`,
    /// `int8`) overrides it, to measure or on a shared Mac.
    public static func mossQuant(_ environment: [String: String],
                                 physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Quant {
        if let raw = environment["MLXIMG_MOSS_QUANT"]?.lowercased(), let chosen = Quant(rawValue: raw),
           [.bf16, .int8].contains(chosen) { return chosen }
        return physicalMemory < 48 << 30 ? .int8 : .bf16
    }

    /// MOSS-Image's Qwen3.5-9B encoder tier (moss-image-swift ≥ 0.2.0, AB-D-0152): bf16 from 48 GB (16.8 GB, loaded per
    /// request), int8 below it (9.4 GB), which takes the per-request encode from 21.8 to 15.7 GB at 1024² on the int8
    /// DiT. `MLXIMG_MOSS_TE_QUANT` (`bf16`, `int8`) overrides it.
    public static func mossTextEncoderQuant(_ environment: [String: String],
                                            physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory)
        -> MossImageTextEncoderQuant {
        if let raw = environment["MLXIMG_MOSS_TE_QUANT"]?.lowercased(),
           let chosen = MossImageTextEncoderQuant(rawValue: raw) { return chosen }
        return physicalMemory < 48 << 30 ? .int8 : .bf16
    }

    /// MOSS-Image (moss-image-swift ≥ 0.3.0: row-band VAE decode, 16.7 GB activation with the bf16 encoder and 10.4 GB
    /// with the int8 one; AB-T-0307; Apache-2.0 weights, MIT port; shipping approved, AB-D-0150).
    /// SFT is the one to pick: long English and Chinese text and JSON layout prompts that place text and objects by
    /// bounding box. Base is the pretrained checkpoint SFT was tuned from, registered for LoRA work and comparison. Both
    /// are prod and permissive, preferred for nothing: 50 steps with CFG is about 2 minutes per 1024² image on an M5 Max.
    /// The weights come from the mlx-community mirrors, pinned; the text encoder, tokenizer and VAE come from the SFT
    /// mirror for both, so a Mac with both stores the 16.8 GB encoder once. `MLXIMG_WEIGHTS_ROOT` folders
    /// `MOSS-Image-SFT` / `MOSS-Image-Base` (upstream snapshots) are read in place.
    static func moss(_ variant: MossImageVariant, _ snapshots: Snapshots, quant: Quant,
                     textEncoderQuant: MossImageTextEncoderQuant) -> CatalogEntry {
        let id = variant == .sft ? "moss-image-sft" : "moss-image-base"
        let packageID = PackageID("imgsrv.\(id)")
        let snapshot = snapshots.path(for: id, folder: variant == .sft ? "MOSS-Image-SFT" : "MOSS-Image-Base")
        let shared = snapshots.path(for: "moss-image-sft", folder: "MOSS-Image-SFT")
        let configuration = MossImageConfiguration(variant: variant, quant: quant, snapshotPath: snapshot ?? "",
                                                   sharedSnapshotPath: shared ?? "", textEncoderQuant: textEncoderQuant)
        let envelope = SizeEnvelope(maxPixels: MossImageEnvelope.maxOutputPixels, multipleOf: 16)
        let defaults = GenerationDefaults(steps: 50, guidance: 3.0)
        let local = (snapshot == nil || shared == nil) ? nil : snapshot
        switch variant {
        case .sft:
            return CatalogEntry(
                id: ModelID(id), packageID: packageID, displayName: "MOSS-Image",
                summary: "MOSS-Image-SFT 5B (OpenMOSS, Apache-2.0) — text-to-image with the strongest long-text rendering "
                    + "in English and Chinese (line breaks kept), and JSON layout prompts that place text and objects by "
                    + "bounding box (summary.caption + items, yxyx in pixels of the requested canvas). 50 steps, CFG 3: about "
                    + "2 minutes per 1024² image on an M5 Max. Sides multiples of 16, 256²–1456² by area.",
                capabilities: [.textToImage], maturity: .prod, envelope: envelope, defaults: defaults, quant: quant,
                localSnapshot: local,
                source: .package(manifest: MossImageSFTPackage.manifest, register: {
                    try await $0.register(MossImageSFTPackage.registration, configuration: configuration, id: packageID)
                }))
        case .base:
            return CatalogEntry(
                id: ModelID(id), packageID: packageID, displayName: "MOSS-Image Base",
                summary: "MOSS-Image-Base 5B (OpenMOSS, Apache-2.0) — the pretrained checkpoint MOSS-Image is tuned from: "
                    + "same prompts and layout JSON, less curated composition; for LoRA work and comparison. 50 steps, CFG 3.",
                capabilities: [.textToImage], maturity: .prod, envelope: envelope, defaults: defaults, quant: quant,
                localSnapshot: local,
                source: .package(manifest: MossImageBasePackage.manifest, register: {
                    try await $0.register(MossImageBasePackage.registration, configuration: configuration, id: packageID)
                }))
        }
    }

    /// FLUX 3 Image Klein's DiT tier on this Mac (flux3-klein-swift ≥ 0.3.0, AB-R-0579). Declared resident + activation:
    /// bf16 11.7 + 12.0 GB, int8 6.7 + 12.0, int4 4.9 + 12.0. The activation is the 2048² envelope's worst case, a
    /// 1664² single reference: the VAE now decodes in row bands. Tiers:
    /// - bf16 from 48 GB (phys 24.5 GB at worst).
    /// - int8 from 32 GB, the same image as bf16 at a seed. 18.7 GB declared would squeeze under a 24 GB Mac's
    ///   19.07 GB budget, but phys would not.
    /// - int4, with 8-bit attention, below that: a different render, text within OCR tolerance. 16.9 GB declared, so a
    ///   24 GB Mac admits it (phys 17.8 GB); before 0.3.0 it declared 20.4 GB and was refused.
    /// Every tier's text is within the pre-registered OCR tolerance of bf16. `MLXIMG_FLUX3_QUANT` (`bf16`, `int8`,
    /// `int4`) overrides it.
    public static func flux3Quant(_ environment: [String: String],
                                  physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Quant {
        if let raw = environment["MLXIMG_FLUX3_QUANT"]?.lowercased(), let chosen = Quant(rawValue: raw),
           [.bf16, .int8, .int4].contains(chosen) { return chosen }
        if physicalMemory >= 48 << 30 { return .bf16 }
        return physicalMemory >= 32 << 30 ? .int8 : .int4
    }

    /// `flux-3-klein`: FLUX 3 Image Klein (Black Forest Labs; flux3-klein-swift ≥ 0.3.0, AB-T-0315).
    /// - Model: text-to-image and editing with up to 10 references in one 5.55B flow-map DiT, 16 steps, no guidance.
    ///   Strong English text rendering, bounding-box layout in the prompt. It needs full scene captions, so the offer's
    ///   summary carries BFL's prompting rules for a calling agent to follow.
    /// - Licence: FLUX Kommunity License. Non-commercial; commercial OUTPUTS only for businesses under US$5M revenue that
    ///   filter content and disclose AI generation; outputs never train a similar model. The LicenseRef is not
    ///   allowlisted, so the entry stamps restricted and the engine offers it by name only, behind --allow-research
    ///   (AB-D-0151).
    /// - Weights: the gated mlx-community mirror, pinned by commit; a first download needs an HF token that has
    ///   accepted the licence. `MLXIMG_WEIGHTS_ROOT/flux-3-image-klein` (BFL's bf16 package) is read in place.
    /// - Envelope (`Flux3KleinEnvelope`): output ≤ 2048² area, sides ×16. The package fits a single reference to 1664²
    ///   itself (its VAE encode is untiled) and refuses nothing for it.
    static func flux3Klein(_ snapshots: Snapshots, quant: Quant) -> CatalogEntry {
        let packageID = PackageID("imgsrv.flux-3-klein")
        let snapshot = snapshots.path(for: "flux-3-klein", folder: "flux-3-image-klein")
        let configuration = Flux3KleinConfiguration(quant: quant, snapshotPath: snapshot ?? "")
        let envelope = SizeEnvelope(maxPixels: Flux3KleinEnvelope.maxOutputPixels, multipleOf: 16)
        return CatalogEntry(
            id: "flux-3-klein", packageID: packageID, displayName: "FLUX 3 Klein",
            summary: "FLUX 3 Image Klein (Black Forest Labs, FLUX Kommunity licence: non-commercial, or commercial outputs "
                + "only for businesses under US$5M revenue that filter content and disclose AI generation; never train on "
                + "outputs) — text-to-image and editing with up to 10 reference images in one 5.55B model, 16 steps. Strong "
                + "English text, bounding-box layout in the prompt. Needs a FULL SCENE CAPTION (style, scene, lighting, "
                + "each subject's colours, materials and position; text in quotes); a short prompt gives generic output. "
                + "Output up to 2048² area, sides multiples of 16; a single reference is fitted to 1664².",
            capabilities: [.textToImage, .imageEdit], maturity: .wip,
            envelope: envelope,
            envelopes: [.imageEdit: SizeEnvelope(maxPixels: Flux3KleinEnvelope.maxOutputPixels, multipleOf: 16,
                                                 maxInputs: Flux3KleinEnvelope.maxReferenceImages)],
            defaults: GenerationDefaults(steps: 16, guidance: 1.0), quant: quant,
            localSnapshot: snapshot,
            source: .package(manifest: Flux3KleinPackage.manifest, register: {
                try await $0.register(Flux3KleinPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    static func ming() -> CatalogEntry {
        let packageID = PackageID("imgsrv.ming-image")
        let configuration = MingImageConfiguration(quant: .int8)
        return CatalogEntry(
            id: "ming-image", packageID: packageID, displayName: "Ming-Image Design",
            summary: "Ming-Image 0.1 Design (MIT) — design-oriented text-to-image with native transparent backgrounds (background: transparent).",
            capabilities: [.textToImage], maturity: .wip,
            envelope: SizeEnvelope(maxPixels: 2048 * 2048, multipleOf: 16),
            defaults: GenerationDefaults(steps: 12, guidance: 1.0), quant: .int8,
            source: .package(manifest: MingImageT2IPackage.manifest, register: {
                try await $0.register(MingImageT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// Boogu has no weight sourcing: it needs the DiT snapshot and its Qwen3-VL conditioner locally. Text-to-image
    /// and editing are separate checkpoints (Base / Edit), so they are separate entries — an edit run on the Base
    /// weights returns noise.
    static func boogu(_ snapshots: Snapshots) -> CatalogEntry? {
        booguVariant(snapshots, id: "boogu", folder: "Boogu-Image-0.1-Base", capability: .textToImage,
                     name: "Boogu Image", summary: "Boogu-Image 0.1 Base (Apache-2.0) — Lumina-family DiT with a Qwen3-VL conditioner; 1024² verified.",
                     defaults: GenerationDefaults(steps: 30, guidance: 3.5))
    }

    static func booguEdit(_ snapshots: Snapshots) -> CatalogEntry? {
        booguVariant(snapshots, id: "boogu-edit", folder: "Boogu-Image-0.1-Edit", capability: .imageEdit,
                     name: "Boogu Image Edit", summary: "Boogu-Image 0.1 Edit (Apache-2.0) — instruction editing with a Qwen3-VL conditioner; 1024² verified.",
                     defaults: GenerationDefaults(steps: 50, guidance: 4.0, width: 768, height: 768))
    }

    private static func booguVariant(_ snapshots: Snapshots, id: String, folder: String, capability: Capability,
                                     name: String, summary: String, defaults: GenerationDefaults) -> CatalogEntry? {
        guard let snapshot = snapshots.path(for: id, folder: folder),
              let qwen = snapshots.path(for: "qwen3-vl", folder: "Qwen3-VL-8B-Instruct") else { return nil }
        let packageID = PackageID("imgsrv.\(id)")
        let configuration = BooguImageConfiguration(snapshotPath: snapshot, qwenPath: qwen, quant: .bf16)
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name, summary: summary,
            capabilities: [capability], maturity: .wip,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, maxInputs: 1),
            defaults: defaults, quant: .bf16, localSnapshot: snapshot,
            source: .package(manifest: BooguImagePackage.manifest, register: {
                try await $0.register(BooguImagePackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// Anima: CircleStone non-commercial weights (eval-acknowledged), local snapshot only.
    static func anima(_ snapshots: Snapshots) -> CatalogEntry? {
        guard let snapshot = snapshots.path(for: "anima") else { return nil }
        let packageID = PackageID("imgsrv.anima")
        let configuration = AnimaConfiguration(snapshotPath: snapshot, quant: .bf16)
        return CatalogEntry(
            id: "anima", packageID: packageID, displayName: "Anima",
            summary: "Anima (CircleStone non-commercial, evaluation only) — anime/illustration text-to-image.",
            capabilities: [.textToImage], maturity: .wip,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16),
            defaults: GenerationDefaults(steps: 30, guidance: 5.0), quant: .bf16, localSnapshot: snapshot,
            source: .package(manifest: AnimaT2IPackage.manifest, register: {
                try await $0.register(AnimaT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// `qwen-image-2.1` — naming the model serves the **Turbo** checkpoint (operator decision, 2026-10-09,
    /// AB-D-0116): the same core and licence posture as the original, the Turbo DiT on its 8 fixed steps (the
    /// checkpoint's `sample_sigmas`; a request's `steps` is ignored), 4–5× the throughput at the same quality
    /// (AB-R-0443). Three local halves — the Turbo snapshot carries only the DiT + pipeline config; the fp32 VAE
    /// comes from the base snapshot and the conditioner from Qwen3-VL-8B-Instruct (AB-R-0437, AB-T-0212). The
    /// 40-step original stays reachable as `qwen-image-2.1-base`.
    static func qwenImage21Turbo(_ snapshots: Snapshots) -> CatalogEntry {
        let packageID = PackageID("imgsrv.qwen-image-2.1")
        let snapshot = snapshots.path(for: "qwen-image-2.1-turbo", folder: "Qwen-Image-2.1-Turbo")
        let base = snapshots.path(for: "qwen-image-2.1", folder: "Qwen-Image-2.1")
        let textEncoder = snapshots.path(for: "qwen3-vl", folder: "Qwen3-VL-8B-Instruct")
        let configuration = QwenImage21TurboConfiguration(
            snapshotPath: snapshot ?? "", vaeSnapshotPath: base ?? "", textEncoderPath: textEncoder ?? "")
        return CatalogEntry(
            id: "qwen-image-2.1", packageID: packageID, displayName: "Qwen-Image-2.1",
            summary: "Qwen-Image-2.1 (Qwen Research licence: non-commercial, research/evaluation only) — served as the "
                + "Turbo checkpoint: the 7B block-causal DiT with a Qwen3-VL-8B conditioner, distilled to 8 fixed steps "
                + "(the checkpoint's own schedule; `steps` is ignored), no guidance; RGBA output with native "
                + "transparency, sizes in multiples of 32 up to 2400×1792 area; editing with up to 10 references at "
                + "≤1024². The 40-step original is `qwen-image-2.1-base`.",
            capabilities: [.textToImage, .imageEdit], maturity: .wip,
            // Same shapes as the base package, so the same measured envelope (AB-R-0290 / AB-R-0310 / AB-R-0441).
            envelope: SizeEnvelope(maxPixels: QwenImage21Envelope.maxTextToImagePixels, multipleOf: 32),
            envelopes: [.imageEdit: SizeEnvelope(maxPixels: QwenImage21Envelope.maxTargetPixels, multipleOf: 32,
                                                 maxInputs: QwenImage21Envelope.maxReferenceImages)],
            defaults: GenerationDefaults(steps: 8, guidance: 1.0), quant: .bf16,
            // Only "downloaded" without the engine's check when all three halves are local.
            localSnapshot: (base == nil || textEncoder == nil) ? nil : snapshot,
            source: .package(manifest: QwenImage21TurboPackage.manifest, register: {
                try await $0.register(QwenImage21TurboPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// `qwen-image-2.1-base` — the original 40-step checkpoint: the parity reference, and the pick for
    /// layout-critical typography where the distill was seen to slip (AB-R-0443). Same licence, same envelopes.
    static func qwenImage21Base(_ snapshots: Snapshots) -> CatalogEntry {
        let packageID = PackageID("imgsrv.qwen-image-2.1-base")
        let snapshot = snapshots.path(for: "qwen-image-2.1", folder: "Qwen-Image-2.1")
        let textEncoder = snapshots.path(for: "qwen3-vl", folder: "Qwen3-VL-8B-Instruct")
        let configuration = QwenImage21Configuration(snapshotPath: snapshot ?? "", textEncoderPath: textEncoder ?? "")
        return CatalogEntry(
            id: "qwen-image-2.1-base", packageID: packageID, displayName: "Qwen-Image-2.1 Base (40 steps)",
            summary: "Qwen-Image-2.1, the original 40-step checkpoint (Qwen Research licence: non-commercial, "
                + "research/evaluation only) — 7B block-causal DiT with a Qwen3-VL-8B conditioner; RGBA output with "
                + "native transparency, sizes in multiples of 32 up to 2400×1792 area; editing with up to 10 references "
                + "at ≤1024². About 5× slower than `qwen-image-2.1` (the Turbo checkpoint); use it for layout-critical "
                + "typography or as the parity reference.",
            capabilities: [.textToImage, .imageEdit], maturity: .wip,
            // The package's measured T2I envelope (AB-R-0290 / AB-R-0310: halo-tiled decode above 1024²).
            envelope: SizeEnvelope(maxPixels: QwenImage21Envelope.maxTextToImagePixels, multipleOf: 32),
            envelopes: [.imageEdit: SizeEnvelope(maxPixels: QwenImage21Envelope.maxTargetPixels, multipleOf: 32,
                                                 maxInputs: QwenImage21Envelope.maxReferenceImages)],
            defaults: GenerationDefaults(steps: 40, guidance: 1.0), quant: .bf16,
            // Only "downloaded" without the engine's check when both halves are local.
            localSnapshot: textEncoder == nil ? nil : snapshot,
            source: .package(manifest: QwenImage21Package.manifest, register: {
                try await $0.register(QwenImage21Package.registration, configuration: configuration, id: packageID)
            }))
    }

}
