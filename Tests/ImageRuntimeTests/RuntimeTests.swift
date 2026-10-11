import Foundation
import ImageServerAPI
import ImageServerCatalog
import ImageServerModels
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
}
