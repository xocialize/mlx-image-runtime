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
