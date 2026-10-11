import Foundation
import ImageServerAPI
import ImageServerCatalog
@testable import ImageServerModels
import MLXHubMetadata
import MLXServeCore
import MLXToolKit
import Testing

// The runtime's own checks, with no model loaded: the catalog, licence classification and request validation. The
// runtime is exercised end to end by its users (ML[X] Image Server's tests; the Pixel Agency Image Engine's
// conformance runs).
@Suite("mlx-image-runtime")
struct RuntimeTests {
    @Test("ForgeCore's processing tiers: unique ids, ForgeCore package ids, at most one preferred tier per capability")
    func processing() {
        let tiers = ModelCatalog.processing()
        #expect(Set(tiers.map(\.id)).count == tiers.count)
        #expect(tiers.allSatisfy { $0.forgeModel != nil && $0.packageID.rawValue.hasPrefix("forge.") })
        for capability in Set(tiers.flatMap(\.capabilities)) {
            #expect(tiers.filter { $0.preferredFor.contains(capability) }.count <= 1, "at most one preferred \(capability.rawValue) tier")
        }
    }

    @Test("The full catalog adds the generative and analysis packages, ids unique, the tiers after them")
    func all() {
        let all = ModelCatalog.all(environment: [:])
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.contains { $0.id == "z-image-turbo" } && all.contains { $0.id == "qwen-image-2.1" } && all.contains { $0.id == "mage-vl" })
        #expect(Array(all.suffix(ModelCatalog.processing().count)).map(\.id) == ModelCatalog.processing().map(\.id))
    }

    @Test("Mage-Flow is prod and permissive (MIT weights and port) but preferred for nothing")
    func mageFlow() {
        let all = ModelCatalog.all(environment: [:])
        for id in ["mage-flow", "mage-flow-turbo", "mage-flow-edit", "mage-flow-edit-turbo", "mage-flow-edit-base"] {
            guard let entry = all.first(where: { $0.id == ModelID(id) }), let manifest = entry.manifest else {
                Issue.record("\(id) missing from the catalog"); continue
            }
            #expect(entry.maturity == .prod, "\(id) is prod")
            #expect(entry.preferredFor.isEmpty, "\(id) is not a preferred default")
            #expect(LicenseClassifier.stamp(for: manifest.license, advisories: []).licenseClass == .permissive)
        }
    }

    @Test("SenseNova-U1.5 is prod and permissive (Apache-2.0 weights, MIT port), every tier edits, preferred for nothing; the fast entry rides the V2 adapter")
    func senseNovaIsProd() throws {
        let entries = ModelCatalog.all(environment: [:])
        for id in ["sensenova-u1", "sensenova-u1-fast", "sensenova-u1-fast-v1"] {
            let entry = try #require(entries.first { $0.id.rawValue == id }, "\(id) is in the catalog")
            #expect(entry.maturity == .prod, "\(id) is prod")
            #expect(Set(entry.capabilities).isSuperset(of: [.textToImage, .imageEdit, .imageAnalysis]), "\(id) serves T2I, edit and VQA")
            #expect(entry.preferredFor.isEmpty, "\(id) is not a preferred default")
            let manifest = try #require(entry.manifest, "\(id) is a package entry")
            #expect(LicenseClassifier.stamp(for: manifest.license, advisories: []).licenseClass == .permissive)
        }
        let fast = try #require(entries.first { $0.id.rawValue == "sensenova-u1-fast" })
        #expect(fast.defaults.steps == 8 && fast.defaults.guidance == 1.0, "the distill entry carries the 8-step cfg-free recipe")
        #expect(fast.quant == .int8)
    }

    @Test("Mage-Flow's content filter is off unless MLXIMG_MAGE_CONTENT_FILTER turns it on (AB-D-0122); Edit Turbo runs int8")
    func mageContentFilter() {
        #expect(!ModelCatalog.mageContentFilter([:]))
        #expect(!ModelCatalog.mageContentFilter(["MLXIMG_MAGE_CONTENT_FILTER": "0"]))
        #expect(ModelCatalog.mageContentFilter(["MLXIMG_MAGE_CONTENT_FILTER": "1"]))
        #expect(ModelCatalog.mageContentFilter(["MLXIMG_MAGE_CONTENT_FILTER": "On"]))
        let off = ModelCatalog.all(environment: [:]).filter { $0.id.rawValue.hasPrefix("mage-flow") }
        let on = ModelCatalog.all(environment: ["MLXIMG_MAGE_CONTENT_FILTER": "1"]).filter { $0.id.rawValue.hasPrefix("mage-flow") }
        #expect(off.count == 5 && on.count == 5)
        #expect(off.allSatisfy { !$0.summary.contains("Content filter on") })
        #expect(on.allSatisfy { $0.summary.contains("Content filter on") })
        #expect(off.first { $0.id == "mage-flow-edit-turbo" }?.quant == .int8)
    }

    @Test("A derived asset inherits the most restrictive licence class of its model and inputs")
    func licences() {
        #expect(LicenseClass.mostRestrictive([.permissive, .evalAcknowledged]) == .evalAcknowledged)
        #expect(LicenseClass.mostRestrictive([.permissive, .restricted, .evalAcknowledged]) == .restricted)
        #expect(LicenseClass.mostRestrictive([]) == .permissive)
    }

    @Test("Seeds stay within 2^53 − 1 so they survive JSON")
    func seeds() {
        #expect(SubmitValidation.maxSeed == 9_007_199_254_740_991)
    }

    @Test("Upscales: ×6 and ×8 only from a tiered model (chains); the tier map; VOSR2 in the catalog")
    func upscaleScales() throws {
        func route(_ id: String, _ package: String) -> RoutedModel {
            RoutedModel(id: ModelID(id), packageID: package, capability: .imageUpscale, displayName: id,
                        license: LicenseStamp(licenseClass: .permissive, weightLicenses: ["Apache-2.0"], portCodeLicense: "MIT"),
                        envelope: SizeEnvelope(maxPixels: 4096 * 4096, multipleOf: 1, maxInputs: 1),
                        defaults: GenerationDefaults(steps: nil, guidance: nil), sourceRepo: "", revision: "")
        }
        func spec(_ scale: Int) -> JobSpec {
            JobSpec(capability: .imageUpscale, params: ["scale": .number(Double(scale))],
                    inputs: ["image": [AssetID(rawValue: "ast_01TEST")]])
        }
        // Routes carry the engine's registration ids, which look nothing like the catalog's.
        func package(_ id: String) -> String { "registration-\(id.count)" }
        let realplksr = route("realplksr-upscale", package("realplksr-upscale"))
        let heart = route("heart-upscale", package("heart-upscale"))
        let vosr2 = route("vosr2-upscale", package("vosr2-upscale"))
        #expect(EngineRunner.tier(for: realplksr) == .best && EngineRunner.tier(for: vosr2) == .generative)
        #expect(EngineRunner.tier(for: route("nacre-upscale", package("nacre-upscale"))) == .generativeClean)
        #expect(EngineRunner.tier(for: heart) == nil, "HEART stays off the tier map")
        #expect(throws: Never.self) { _ = try SubmitValidation.validate(spec(6), route: realplksr) }
        #expect(throws: Never.self) { _ = try SubmitValidation.validate(spec(8), route: vosr2) }
        #expect(throws: APIError.self) { _ = try SubmitValidation.validate(spec(8), route: heart) }
        #expect(throws: APIError.self) { _ = try SubmitValidation.validate(spec(3), route: realplksr) }
    }

    @Test("A failed download names the repo and what the hub said; other failures pass through (AB-T-0221)")
    func downloadErrors() {
        let missing = PendingDownload.Source(role: "snapshot", repo: "mlx-community/Z-Image-Turbo-4bit", bytes: nil)
        let failure = WeightDownloadError(model: "z-image-turbo", sources: [missing], underlying: HubMetadataError.httpStatus(404))
        #expect("\(failure)" == "Downloading weights for z-image-turbo from mlx-community/Z-Image-Turbo-4bit (snapshot) failed: "
                + "the hub has no such repo or revision, or it is private or gated (HTTP 404 on its file listing).")
        let transfer = WeightMaterializer.MaterializeError.httpStatus("transformer/a.safetensors", 503)
        #expect("\(WeightDownloadError(model: "m", sources: [], underlying: transfer))"
                == "Downloading weights for m failed: Download of transformer/a.safetensors failed (HTTP 503).")
        #expect(WeightDownloadError.isDownloadFailure(HubMetadataError.httpStatus(404)))
        #expect(WeightDownloadError.isDownloadFailure(transfer))
        #expect(WeightDownloadError.isDownloadFailure(URLError(.notConnectedToInternet)))
        #expect(!WeightDownloadError.isDownloadFailure(URLError(.cancelled)))
        #expect(!WeightDownloadError.isDownloadFailure(CancellationError()))

        let sized = PendingDownload(model: "m", sources: [
            .init(role: "a", repo: "o/a", bytes: 10), .init(role: "b", repo: "o/b", bytes: 0), missing,
        ], freeBytes: nil)
        #expect(sized.unresolved.map(\.repo) == ["o/b", "mlx-community/Z-Image-Turbo-4bit"])
        #expect(sized.totalBytes == nil)
        #expect(PendingDownload(model: "m", sources: [.init(role: "a", repo: "o/a", bytes: 10)], freeBytes: nil).totalBytes == 10)
    }
}
