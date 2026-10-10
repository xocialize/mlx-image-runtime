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
}
