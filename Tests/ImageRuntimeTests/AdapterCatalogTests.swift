import Foundation
import ImageServerAPI
import ImageServerCatalog
@testable import ImageServerModels
import MLXHubMetadata
import MLXKlein
import MLXToolKit
import Testing

// The adapter catalog and typed adapters through the runtime (AB-A-0191 part 2): the vendored format-3 registries,
// submit-time and mapping-time checks against the routed surface, and adapter-implied routing on a real engine
// (packages registered, nothing loaded).
@Suite("Adapter catalog")
struct AdapterCatalogTests {
    static let catalog = ModelCatalog.adapterCatalog()

    @Test("The vendored registries decode: Klein's 7 and Qwen-Image Flash's 27, ids qualified, nothing skipped")
    func bundled() {
        #expect(Self.catalog.skipped.isEmpty, "\(Self.catalog.skipped)")
        let ids = Self.catalog.entries.map(\.descriptor.id)
        #expect(ids.filter { $0.hasPrefix("flux2-klein:") }.count == 7)
        #expect(ids.filter { $0.hasPrefix("qwen-image:") }.count == 27)
        #expect(!ids.contains("flux2-klein:object-remove"), "withdrawn entries never register")
        let tryon = Self.catalog.entries.first { $0.descriptor.id == "flux2-klein:tryon" }
        #expect(tryon?.descriptor.footprint?.activationMultiplier == 1.02)
        #expect(tryon?.info.conditioning.map(\.role) == ["person", "top", "bottom"])
        #expect(tryon?.info.clearance == ["flux2-klein-4b": "perceptual"])
        let martha = Self.catalog.entries.first { $0.descriptor.id == "qwen-image:martha" }?.info
        #expect(martha?.commercialUse == "conditional" && martha?.notice != nil)
    }

    @Test("A registry entry the engine would refuse is skipped with its reason, not fatal")
    func skipsUnregistrable() throws {
        let json = #"""
        {"format": "adapter-registry", "schemaVersion": 3, "namespace": "t", "adapters": [
          {"id": "ok", "title": "OK", "kind": "plain", "format": "bfl-fused", "baseModels": ["flux2-klein-4b"],
           "capabilities": ["imageEdit"], "license": "Apache-2.0", "defaultStrength": 1,
           "licenseTerms": {"commercialUse": "allowed", "gated": false}, "status": "candidate",
           "source": {"repo": "o/r", "revision": "0123456789012345678901234567890123456789", "file": "a.safetensors",
                      "sha256": "\#(String(repeating: "a", count: 64))"}},
          {"id": "ic-no-footprint", "title": "IC", "kind": "ic", "format": "bfl-fused", "baseModels": ["flux2-klein-4b"],
           "capabilities": ["imageEdit"], "license": "Apache-2.0", "defaultStrength": 1,
           "conditioning": [{"role": "pose", "media": "image", "required": true}],
           "licenseTerms": {"commercialUse": "allowed", "gated": false}, "status": "candidate",
           "source": {"repo": "o/r", "revision": "0123456789012345678901234567890123456789", "file": "b.safetensors",
                      "sha256": "\#(String(repeating: "b", count: 64))"}}],
         "withdrawn": [{"id": "gone", "title": "Gone", "reason": "bad bytes", "date": "2026-10-19"}]}
        """#
        let decoded = try AdapterCatalog.decode(Data(json.utf8))
        #expect(decoded.entries.map(\.descriptor.id) == ["t:ok"])
        #expect(decoded.skipped.map(\.id) == ["t:ic-no-footprint"])
        #expect(decoded.skipped.first?.reason.contains("footprint") == true)
        #expect(throws: (any Error).self) {
            _ = try AdapterCatalog.decode(Data(#"{"format": "adapter-registry", "schemaVersion": 2, "namespace": "x"}"#.utf8))
        }
    }

    /// Klein's edit route as the service builds it.
    static func kleinEdit() -> RoutedModel {
        let support = KleinAdapters.support(.imageEdit)
        return RoutedModel(id: ModelID("klein-4b"), packageID: "imgsrv.klein-4b", capability: .imageEdit,
                           displayName: "FLUX.2 Klein 4B",
                           license: LicenseStamp(licenseClass: .permissive, weightLicenses: ["Apache-2.0"], portCodeLicense: "MIT"),
                           envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, maxInputs: 4),
                           defaults: GenerationDefaults(steps: 4, guidance: 1), sourceRepo: "", revision: "",
                           adapterSupport: support,
                           adapters: catalog.entries.map(\.descriptor).filter { support.mismatch($0, capability: .imageEdit) == nil })
    }

    static func spec(_ adapters: [JobAdapter], inputs: [String: [AssetID]] = ["images": [AssetID(rawValue: "ast_1")]],
                     capability: Capability = .imageEdit) -> JobSpec {
        JobSpec(capability: capability, params: ["prompt": "x"], inputs: inputs, adapters: adapters)
    }

    @Test("Submit: an adapter that fits passes; unknown ids, misfits, bad strength and bad conditioning are 4xx")
    func submit() throws {
        let route = Self.kleinEdit()
        #expect(route.adapters.count == 7)
        _ = try SubmitValidation.validate(Self.spec([JobAdapter(id: "flux2-klein:outpaint")]), route: route)

        func problem(_ spec: JobSpec) -> APIError? {
            do { _ = try SubmitValidation.validate(spec, route: route); return nil } catch let e as APIError { return e }
            catch { return nil }
        }
        #expect(problem(Self.spec([JobAdapter(id: "qwen-image:martha")]))?.code == "unsupported_parameter")
        #expect(problem(Self.spec([JobAdapter(id: "nope:nope")]))?.code == "unsupported_parameter")
        #expect(problem(Self.spec([JobAdapter(id: "flux2-klein:outpaint", strength: 3)]))?.message.contains("strength") == true)
        // IC: every required role bound to a present input; none of the capability's own slot names.
        let pose = JobAdapter(id: "flux2-klein:refcontrol-pose", conditioning: ["pose": "skeleton", "reference": "subject"])
        let inputs: [String: [AssetID]] = ["skeleton": [AssetID(rawValue: "ast_s")], "subject": [AssetID(rawValue: "ast_r")]]
        #expect(problem(Self.spec([pose], inputs: inputs)) == nil, "an IC edit needs no other image")
        #expect(problem(Self.spec([pose], inputs: ["skeleton": [AssetID(rawValue: "ast_s")]]))?.code == "missing_input")
        #expect(problem(Self.spec([JobAdapter(id: "flux2-klein:refcontrol-pose", conditioning: ["pose": "images"])]))?
            .code == "param_out_of_range")
        #expect(problem(Self.spec([JobAdapter(id: "flux2-klein:refcontrol-pose", conditioning: ["pose": "skeleton"])],
                                  inputs: inputs))?.message.contains("reference") == true, "a required role is missing")
        // Two IC refs plus three images exceed klein's 4-reference envelope.
        var crowded = inputs
        crowded["images"] = (1...3).map { AssetID(rawValue: "ast_\($0)") }
        #expect(problem(Self.spec([pose], inputs: crowded))?.code == "too_many_inputs")
        // A route without AdapterSupport takes none.
        var bare = route
        bare.adapterSupport = nil
        #expect(problem(Self.spec([JobAdapter(id: "flux2-klein:outpaint")])).map { _ in true } == nil)
        do { _ = try SubmitValidation.validate(Self.spec([JobAdapter(id: "flux2-klein:outpaint")]), route: bare)
             Issue.record("adapters passed on a route that takes none") } catch {}
    }

    @Test("Mapping: adapters reach the request as AdapterRefs, conditioning carrying the named inputs' images")
    func mapping() throws {
        let skeleton = MLXToolKit.Image(format: .png, data: Data([1]), width: 1, height: 1)
        let subject = MLXToolKit.Image(format: .png, data: Data([2]), width: 1, height: 1)
        let spec = Self.spec([JobAdapter(id: "flux2-klein:refcontrol-pose", strength: 0.8,
                                         conditioning: ["pose": "skeleton", "reference": "subject"]),
                              JobAdapter(id: "flux2-klein:zoom")], inputs: [:])
        let work = RunWork(route: Self.kleinEdit(), spec: spec, seed: 1, width: nil, height: nil,
                           inputs: ["skeleton": [skeleton], "subject": [subject]])
        let edit = try #require(try RequestMapping.request(for: work) as? IEditRequest)
        #expect(edit.adapters.map(\.id) == ["flux2-klein:refcontrol-pose", "flux2-klein:zoom"])
        #expect(edit.adapters[0].strength == 0.8)
        #expect(Set(edit.adapters[0].conditioning.map(\.role)) == ["pose", "reference"])
        #expect(edit.images.isEmpty, "the IC references ride the adapter, not images")
        // The mapping runs the same pre-flight as submit, for hosts that build RunWork themselves.
        let bad = RunWork(route: Self.kleinEdit(), spec: Self.spec([JobAdapter(id: "qwen-image:martha")]), seed: 1,
                          width: nil, height: nil, inputs: ["images": [subject]])
        #expect(throws: JobError.self) { _ = try RequestMapping.request(for: bad) }
    }

    @Test("JobSpec carries adapters on the wire")
    func wire() throws {
        let json = #"{"capability":"imageEdit","params":{"prompt":"x"},"adapters":[{"id":"flux2-klein:refcontrol-pose","strength":0.9,"conditioning":{"pose":"skeleton"}},{"id":"flux2-klein:zoom"}]}"#
        let spec = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        #expect(spec.adapters == [JobAdapter(id: "flux2-klein:refcontrol-pose", strength: 0.9, conditioning: ["pose": "skeleton"]),
                                  JobAdapter(id: "flux2-klein:zoom")])
        #expect(try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec)) == spec)
    }

    @Test("Engine: the catalog registers, each model lists the adapters it takes, and an adapter implies its model")
    @MainActor
    func engineRouting() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store) }
        let wanted: Set<ModelID> = ["z-image-turbo", "klein-4b", "qwen-image-flash"]
        let catalog = ModelCatalog.all(environment: [:]).filter { wanted.contains($0.id) }
        let (service, forge) = await ImageEngineService.bootstrap(storeRoot: store, catalog: catalog,
                                                                  adapters: ModelCatalog.adapters())
        _ = forge
        let registered = await service.adapterCatalog()
        #expect(registered.failures.isEmpty, "\(registered.failures)")
        #expect(registered.registered.count == 34)

        let klein = try #require(await service.model("klein-4b"))
        #expect(klein.adapters.count == 7)
        let flash = try #require(await service.model("qwen-image-flash"))
        #expect(flash.adapters.count == 27 && flash.adapters.allSatisfy { $0.id.hasPrefix("qwen-image:") })
        #expect(try #require(await service.model("z-image-turbo")).adapters.isEmpty)

        // T2I defaults to Z-Image Turbo; a Qwen-Image adapter implies Flash, a klein one Klein.
        #expect(try await service.route(.textToImage, model: nil, adapters: []).id == "z-image-turbo")
        #expect(try await service.route(.textToImage, model: nil, adapters: ["qwen-image:martha"]).id == "qwen-image-flash")
        #expect(try await service.route(.imageEdit, model: nil, adapters: ["flux2-klein:tryon"]).id == "klein-4b")
        let routed = try await service.route(.imageEdit, model: "klein-4b", adapters: ["flux2-klein:tryon"])
        #expect(routed.adapterSupport?.baseModel == "flux2-klein-4b" && routed.adapters.count == 7)
        await #expect(throws: APIError.self) {
            _ = try await service.route(.textToImage, model: nil, adapters: ["qwen-image:martha", "flux2-klein:zoom"])
        }
        let preview = await service.adapterDownloadCheck(["flux2-klein:zoom"])
        #expect(preview.totalBytes == 76_039_072, "nothing on disk yet: the preview sizes the pinned file")
    }
}
