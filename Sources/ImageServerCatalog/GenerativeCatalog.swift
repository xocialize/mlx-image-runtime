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
        var entries: [CatalogEntry] = [
            zImageTurbo(snapshots), kleinTurbo(), zImage(snapshots), kleinBase(), qwenImageFlash(), qwenImageEdit(),
            mageFlow(.flow, id: "mage-flow", name: "Mage-Flow"),
            mageFlow(.turbo, id: "mage-flow-turbo", name: "Mage-Flow Turbo"),
            mageFlowEdit(.edit, id: "mage-flow-edit", name: "Mage-Flow Edit"),
            mageFlowEdit(.editTurbo, id: "mage-flow-edit-turbo", name: "Mage-Flow Edit Turbo"),
            mageFlowEdit(.editBase, id: "mage-flow-edit-base", name: "Mage-Flow Edit Base"),
            senseNova(.q8, id: "sensenova-u1", name: "SenseNova-U1.5"),
            senseNova(.fast8, id: "sensenova-u1-fast", name: "SenseNova-U1.5 8-step"),
            ming(),
        ]
        // Local-weights-only packages register only when their weights are present.
        if let boogu = boogu(snapshots) { entries.append(boogu) }
        if let booguEdit = booguEdit(snapshots) { entries.append(booguEdit) }
        if let anima = anima(snapshots) { entries.append(anima) }
        // Qwen-Image-2.1: naming it serves the Turbo checkpoint; the 40-step original is `qwen-image-2.1-base`.
        entries.append(qwenImage21Turbo(snapshots))
        entries.append(qwenImage21Base(snapshots))
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

    /// Mage-Flow (MIT weights and port, mage-flow-swift ≥ 0.9.1) is prod: offered by default, preferred for nothing.
    static func mageFlow(_ variant: MageFlowVariant, id: String, name: String) -> CatalogEntry {
        let packageID = PackageID("imgsrv.\(id)")
        let configuration = MageFlowConfiguration(variant: variant, quant: .bf16)
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name,
            summary: "\(name) (MIT) — square text-to-image with a fail-closed content filter.",
            capabilities: [.textToImage], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, requiresSquare: true),
            defaults: GenerationDefaults(steps: variant.defaultSteps, guidance: Double(variant.defaultGuidance)),
            quant: .bf16,
            source: .package(manifest: MageFlowT2IPackage.manifest, register: {
                try await $0.register(MageFlowT2IPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    /// The edit checkpoints: RL-aligned (`.edit`, 20 steps), distilled Turbo (4 steps) and Base (30 steps). Turbo and
    /// Base are the removal gate's named route (AB-R-0464) and the Image Engine's erase tier (AB-T-0220).
    static func mageFlowEdit(_ variant: MageFlowVariant, id: String, name: String) -> CatalogEntry {
        let packageID = PackageID("imgsrv.\(id)")
        let configuration = MageFlowConfiguration(variant: variant, quant: .bf16)
        let tier = variant == .editTurbo ? " Distilled, 4 steps." : variant == .editBase ? " Quality tier, 30 steps." : ""
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name,
            summary: "\(name) (MIT) — square instruction editing with up to 3 references and a fail-closed content filter."
                + tier,
            capabilities: [.imageEdit], maturity: .prod,
            envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, maxInputs: 3, requiresSquare: true),
            defaults: GenerationDefaults(steps: variant.defaultSteps, guidance: Double(variant.defaultGuidance)),
            quant: .bf16,
            source: .package(manifest: MageFlowEditPackage.manifest, register: {
                try await $0.register(MageFlowEditPackage.registration, configuration: configuration, id: packageID)
            }))
    }

    // MARK: - Work in progress generative (named use only)

    static func senseNova(_ variant: SenseNovaVariant, id: String, name: String) -> CatalogEntry {
        let packageID = PackageID("imgsrv.\(id)")
        let configuration = SenseNovaU1Configuration(variant: variant)
        let distilled = variant == .fast8 || variant == .fast4
        return CatalogEntry(
            id: ModelID(id), packageID: packageID, displayName: name,
            summary: "SenseNova-U1.5 8B MoT (Apache-2.0) — unified understanding + generation; sizes in multiples of 32"
                + (distilled ? "; distilled 8-step (no editing)." : "; also instruction editing."),
            capabilities: distilled ? [.textToImage] : [.textToImage, .imageEdit], maturity: .wip,
            envelope: SizeEnvelope(maxPixels: 2048 * 2048, multipleOf: 32, maxInputs: 1),
            defaults: GenerationDefaults(steps: distilled ? 8 : 50, guidance: distilled ? 1.0 : 4.0),
            quant: variant == .bf16 ? .bf16 : (variant == .fast4 ? .int4 : .int8),
            source: .package(manifest: SenseNovaU1Package.manifest, register: {
                try await $0.register(SenseNovaU1Package.registration, configuration: configuration, id: packageID)
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
