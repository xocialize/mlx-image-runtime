import Foundation
import ImageServerAPI
import Testing

@Suite("Brand application records")
struct BrandApplicationTests {
    @Test("A shared kit's owner round-trips; records written before `owner` existed still decode")
    func owner() throws {
        let shared = BrandApplication(kitID: "bk_1", reference: "acme/core@4", revision: 4, resolvedBy: "explicit", applied: [.style],
                                      userPrompt: "a mug", effectivePrompt: nil, effectiveNegative: nil, modelSource: "default",
                                      params: [:], referenceInputs: [], notes: [], owner: "Brand")
        let data = try JSONEncoder().encode(shared)
        #expect(try JSONDecoder().decode(BrandApplication.self, from: data).owner == "Brand")

        let old = #"{"kit_id":"bk_1","reference":"acme/core@2","revision":2,"resolved_by":"project","applied":["style"],"model_source":"default","params":{},"reference_inputs":[],"notes":[]}"#
        let decoded = try JSONDecoder().decode(BrandApplication.self, from: Data(old.utf8))
        #expect(decoded.owner == nil && decoded.reference == "acme/core@2")
    }
}

@Suite("Brand delivery specs")
struct BrandDeliveryTests {
    @Test("A kit's delivery specs round-trip; manifests without them, and formats this version doesn't know, still decode")
    func delivery() throws {
        let manifest = BrandManifest(displayName: "Acme", delivery: [
            BrandDelivery(name: "Web hero", format: .web, floor: 75, sizes: [2048, 1080]),
            BrandDelivery(name: "Print proofs", format: .native, floor: 90),
        ])
        let decoded = try JSONDecoder().decode(BrandManifest.self, from: try JSONEncoder().encode(manifest))
        #expect(decoded == manifest)

        let old = try JSONDecoder().decode(BrandManifest.self, from: Data(#"{"displayName":"Acme","rules":["Sentence case"]}"#.utf8))
        #expect(old.delivery.isEmpty && old.rules == ["Sentence case"])

        let future = try JSONDecoder().decode(BrandManifest.self, from: Data(#"{"delivery":[{"name":"Billboard","format":"jxl","sizes":[8192]}]}"#.utf8))
        #expect(future.delivery == [BrandDelivery(name: "Billboard", format: .web, floor: 75, sizes: [8192])])
    }
}
