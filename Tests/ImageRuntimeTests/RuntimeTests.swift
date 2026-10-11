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
        for id in ["mage-flow", "mage-flow-turbo", "mage-flow-edit"] {
            guard let entry = all.first(where: { $0.id == ModelID(id) }), let manifest = entry.manifest else {
                Issue.record("\(id) missing from the catalog"); continue
            }
            #expect(entry.maturity == .prod, "\(id) is prod")
            #expect(entry.preferredFor.isEmpty, "\(id) is not a preferred default")
            #expect(LicenseClassifier.stamp(for: manifest.license, advisories: []).licenseClass == .permissive)
        }
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
