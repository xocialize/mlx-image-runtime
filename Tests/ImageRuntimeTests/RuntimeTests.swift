import Foundation
import ImageServerAPI
import ImageServerCatalog
import MossImage
@testable import ImageServerModels
import MLXHubMetadata
import MLXMageFlow
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
        // Anime4K VL (AB-A-0183): the weightless Instant tier, reachable by name, preferred for nothing.
        let anime4k = tiers.first { $0.id == "anime4k-upscale" }
        #expect(anime4k?.forgeModel == .upscaleInstant && anime4k?.preferredFor.isEmpty == true)
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

    @Test("Anima is gone (AB-D-0190): no entry, even with a snapshot configured")
    func animaRemoved() {
        let environment = ["MLXIMG_SNAPSHOT_ANIMA": NSTemporaryDirectory(), "MLXIMG_WEIGHTS_ROOT": NSTemporaryDirectory()]
        let all = ModelCatalog.all(environment: environment)
        #expect(!all.contains { $0.id.rawValue.lowercased().contains("anima") })
        #expect(!all.contains { $0.packageID.rawValue == "imgsrv.anima" })
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

    @Test("MOSS-Image SFT and Base are prod and permissive T2I, preferred for nothing, 50 steps CFG 3 under the 1456² cap (AB-T-0307)")
    func mossImage() throws {
        let entries = ModelCatalog.all(environment: [:])
        for id in ["moss-image-sft", "moss-image-base"] {
            let entry = try #require(entries.first { $0.id.rawValue == id }, "\(id) is in the catalog")
            #expect(entry.packageID.rawValue == "imgsrv.\(id)")
            #expect(entry.maturity == .prod && entry.preferredFor.isEmpty, "\(id) is prod, not a default")
            #expect(entry.capabilities == [.textToImage])
            #expect(entry.defaults.steps == 50 && entry.defaults.guidance == 3.0)
            #expect(entry.envelope.maxPixels == 1456 * 1456 && entry.envelope.multipleOf == 16)
            let manifest = try #require(entry.manifest, "\(id) is a package entry")
            #expect(LicenseClassifier.stamp(for: manifest.license, advisories: []).licenseClass == .permissive)
        }
    }

    @Test("FLUX 3 Klein is restricted (FLUX Kommunity licence, not allowlisted), wip, preferred for nothing; T2I + edit at 2048², 10 refs")
    func flux3Klein() throws {
        let all = ModelCatalog.all(environment: [:])
        let entry = try #require(all.first { $0.id == "flux-3-klein" })
        #expect(entry.maturity == .wip)
        #expect(entry.preferredFor.isEmpty)
        #expect(Set(entry.capabilities) == [.textToImage, .imageEdit])
        #expect(entry.defaults.steps == 16)
        #expect(entry.envelope.maxPixels == 2048 * 2048 && entry.envelope.multipleOf == 16)
        #expect(entry.envelopes[.imageEdit]?.maxPixels == 2048 * 2048)
        #expect(entry.envelopes[.imageEdit]?.maxInputs == 10)
        let manifest = try #require(entry.manifest)
        let stamp = LicenseClassifier.stamp(for: manifest.license, advisories: [])
        #expect(stamp.licenseClass == .restricted)
        #expect(stamp.weightLicenses == ["LicenseRef-FLUX-Kommunity-1.0"])
    }

    @Test("FLUX 3 Klein's prompt upsampler is int8 by default; MLXIMG_FLUX3_UPSAMPLER overrides it (off / bf16 / int8 / int4)")
    func flux3Upsampler() {
        #expect(ModelCatalog.flux3Upsampler([:]) == .int8)
        #expect(ModelCatalog.flux3Upsampler(["MLXIMG_FLUX3_UPSAMPLER": "OFF"]) == .off)
        #expect(ModelCatalog.flux3Upsampler(["MLXIMG_FLUX3_UPSAMPLER": "int4"]) == .int4)
        #expect(ModelCatalog.flux3Upsampler(["MLXIMG_FLUX3_UPSAMPLER": "int2"]) == .int8, "not a tier")
    }

    @Test("FLUX 3 Klein's safety checks are off by default; MLXIMG_FLUX3_SAFETY=1 / on / true turns them on")
    func flux3Safety() {
        #expect(!ModelCatalog.flux3Safety([:]))
        #expect(ModelCatalog.flux3Safety(["MLXIMG_FLUX3_SAFETY": "1"]))
        #expect(ModelCatalog.flux3Safety(["MLXIMG_FLUX3_SAFETY": "ON"]))
        #expect(!ModelCatalog.flux3Safety(["MLXIMG_FLUX3_SAFETY": "0"]))
        let off = ModelCatalog.generative(environment: [:]).first { $0.id == "flux-3-klein" }
        let on = ModelCatalog.generative(environment: ["MLXIMG_FLUX3_SAFETY": "true"]).first { $0.id == "flux-3-klein" }
        #expect(off?.summary.contains("Safety checks on") == false)
        #expect(on?.summary.contains("Safety checks on (fail-closed)") == true)
    }

    @Test("FLUX 3 Klein's DiT runs bf16 from 48 GB, int8 from 32 GB, int4 below; MLXIMG_FLUX3_QUANT overrides")
    func flux3Quant() {
        #expect(ModelCatalog.flux3Quant([:], physicalMemory: 128 << 30) == .bf16)
        #expect(ModelCatalog.flux3Quant([:], physicalMemory: 48 << 30) == .bf16)
        #expect(ModelCatalog.flux3Quant([:], physicalMemory: 36 << 30) == .int8)
        #expect(ModelCatalog.flux3Quant([:], physicalMemory: 32 << 30) == .int8)
        #expect(ModelCatalog.flux3Quant([:], physicalMemory: 24 << 30) == .int4)
        #expect(ModelCatalog.flux3Quant([:], physicalMemory: 16 << 30) == .int4)
        #expect(ModelCatalog.flux3Quant(["MLXIMG_FLUX3_QUANT": "INT4"], physicalMemory: 128 << 30) == .int4)
        #expect(ModelCatalog.flux3Quant(["MLXIMG_FLUX3_QUANT": "bf16"], physicalMemory: 24 << 30) == .bf16)
        #expect(ModelCatalog.flux3Quant(["MLXIMG_FLUX3_QUANT": "int3"], physicalMemory: 128 << 30) == .bf16, "not a declared tier")
    }

    @Test("MOSS-Image's DiT runs bf16 from 48 GB and int8 below (AB-D-0152); MLXIMG_MOSS_QUANT overrides with bf16 or int8 only")
    func mossQuant() {
        #expect(ModelCatalog.mossQuant([:], physicalMemory: 128 << 30) == .bf16)
        #expect(ModelCatalog.mossQuant([:], physicalMemory: 48 << 30) == .bf16)
        #expect(ModelCatalog.mossQuant([:], physicalMemory: 47 << 30) == .int8)
        #expect(ModelCatalog.mossQuant([:], physicalMemory: 36 << 30) == .int8)
        #expect(ModelCatalog.mossQuant([:], physicalMemory: 32 << 30) == .int8)
        #expect(ModelCatalog.mossQuant([:], physicalMemory: 24 << 30) == .int8)
        #expect(ModelCatalog.mossQuant(["MLXIMG_MOSS_QUANT": "int8"], physicalMemory: 128 << 30) == .int8)
        #expect(ModelCatalog.mossQuant(["MLXIMG_MOSS_QUANT": "BF16"], physicalMemory: 24 << 30) == .bf16)
        #expect(ModelCatalog.mossQuant(["MLXIMG_MOSS_QUANT": "int4"], physicalMemory: 128 << 30) == .bf16, "int4 is not a declared tier")
    }

    @Test("MOSS-Image's encoder runs bf16 from 48 GB and int8 below (AB-D-0152); MLXIMG_MOSS_TE_QUANT overrides it")
    func mossTextEncoderQuant() {
        #expect(ModelCatalog.mossTextEncoderQuant([:], physicalMemory: 128 << 30) == .bf16)
        #expect(ModelCatalog.mossTextEncoderQuant([:], physicalMemory: 48 << 30) == .bf16)
        #expect(ModelCatalog.mossTextEncoderQuant([:], physicalMemory: 47 << 30) == .int8)
        #expect(ModelCatalog.mossTextEncoderQuant([:], physicalMemory: 36 << 30) == .int8)
        #expect(ModelCatalog.mossTextEncoderQuant([:], physicalMemory: 32 << 30) == .int8)
        #expect(ModelCatalog.mossTextEncoderQuant(["MLXIMG_MOSS_TE_QUANT": "int8"], physicalMemory: 128 << 30) == .int8)
        #expect(ModelCatalog.mossTextEncoderQuant(["MLXIMG_MOSS_TE_QUANT": "BF16"], physicalMemory: 32 << 30) == .bf16)
        #expect(ModelCatalog.mossTextEncoderQuant(["MLXIMG_MOSS_TE_QUANT": "int4"], physicalMemory: 32 << 30) == .int8,
                "int4 is not an encoder tier")
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

    @Test("Edits forward initSigma to the model's metaData (Mage-Flow's partial start, AB-D-0126); out of (0, 1] is refused")
    func initSigma() throws {
        let editor = RoutedModel(id: ModelID("mage-flow-edit-turbo"), packageID: "mage", capability: .imageEdit, displayName: "Mage",
                                 license: LicenseStamp(licenseClass: .permissive, weightLicenses: ["MIT"], portCodeLicense: "MIT"),
                                 envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, maxInputs: 3),
                                 defaults: GenerationDefaults(steps: 4, guidance: 1), sourceRepo: "", revision: "")
        func spec(_ params: JSONObject) -> JobSpec { JobSpec(capability: .imageEdit, params: params, count: 1) }
        func work(_ params: JSONObject) -> RunWork {
            RunWork(route: editor, spec: spec(params), seed: 1, width: 512, height: 512, inputs: [:], outputIndex: 0)
        }
        let partial = try #require(try RequestMapping.request(for: work(["prompt": "upscale", "initSigma": 0.9])) as? IEditRequest)
        #expect(partial.metaData["initSigma"] == .double(0.9))
        let plain = try #require(try RequestMapping.request(for: work(["prompt": "upscale"])) as? IEditRequest)
        #expect(plain.metaData["initSigma"] == nil, "absent means a normal edit")
        #expect(throws: APIError.self) { _ = try SubmitValidation.validate(spec(["prompt": "x", "initSigma": 1.5]), route: editor) }
        #expect(throws: APIError.self) { _ = try SubmitValidation.validate(spec(["prompt": "x", "initSigma": 0]), route: editor) }
    }

    @Test("Mage-Flow-Edit's tiles mode reaches the model whole: every image, the tile side, the base seed and initSigma (mage-flow-swift ≥ 0.11.0)")
    func tilesMode() throws {
        let editor = RoutedModel(id: ModelID("mage-flow-edit-turbo"), packageID: "mage", capability: .imageEdit, displayName: "Mage",
                                 license: LicenseStamp(licenseClass: .permissive, weightLicenses: ["MIT"], portCodeLicense: "MIT"),
                                 envelope: SizeEnvelope(maxPixels: 1024 * 1024, multipleOf: 16, maxInputs: 3),
                                 defaults: GenerationDefaults(steps: 4, guidance: 1), sourceRepo: "", revision: "")
        let tiles = (0..<7).map { _ in Image(format: .png, data: Data(), width: 896, height: 896) }
        let work = RunWork(route: editor, spec: JobSpec(capability: .imageEdit, mode: "tiles",
                                                         params: ["prompt": "upscale", "initSigma": 0.9], count: 1),
                           seed: 41, width: 896, height: 896, inputs: ["images": tiles], outputIndex: 0)
        let request = try #require(try RequestMapping.request(for: work) as? IEditRequest)
        #expect(request.mode?.rawValue == "tiles")
        #expect(request.images.count == 7, "a tiles request is not held to the 3-reference envelope")
        #expect(request.width == 896 && request.height == 896)
        #expect(request.seed == 41, "tile k runs at seed + k inside the package")
        #expect(request.metaData["initSigma"] == .double(0.9))
        #expect(MageFlowModes.tiles.rawValue == "tiles")
        #expect(MageFlowEditPackage.manifest.surfaces.first?.supportedModes.contains(MageFlowModes.tiles) == true)
    }

    @Test("Package keys reach the request's metaData (AB-A-0191): FLUX 3 Klein's upsample and boxes on generate and edit")
    func metaDataPassThrough() throws {
        func route(_ capability: Capability) -> RoutedModel {
            RoutedModel(id: ModelID("flux-3-klein"), packageID: "imgsrv.flux-3-klein", capability: capability,
                        displayName: "FLUX 3 Klein",
                        license: LicenseStamp(licenseClass: .restricted, weightLicenses: ["LicenseRef-FLUX-Kommunity-1.0"],
                                              portCodeLicense: "MIT"),
                        envelope: SizeEnvelope(maxPixels: 2048 * 2048, multipleOf: 16, maxInputs: 10),
                        defaults: GenerationDefaults(steps: 16, guidance: 1), sourceRepo: "", revision: "",
                        requestKeys: ModelCatalog.flux3RequestKeys)
        }
        let box: JSONValue = ["id": "sign", "bbox": [0, 0.25, 0.5, 1], "desc": "a red sign"]
        let meta: JSONObject = ["upsample": false, "boxes": [box], "unset": nil]
        let t2i = JobSpec(capability: .textToImage, params: ["prompt": "a sign"], metaData: meta)
        let generate = try #require(try RequestMapping.request(
            for: RunWork(route: route(.textToImage), spec: t2i, seed: 1, width: 1024, height: 1024)) as? T2IRequest)
        #expect(generate.metaData["upsample"] == .bool(false))
        #expect(generate.metaData["boxes"] == .array([.object(["id": .string("sign"), "desc": .string("a red sign"),
                                                               "bbox": .array([.int(0), .double(0.25), .double(0.5), .int(1)])])]))
        #expect(generate.metaData["unset"] == nil, "a null value means unset")

        let edit = JobSpec(capability: .imageEdit, params: ["prompt": "make it blue", "strength": 0.5],
                           metaData: ["upsample": true])
        let editing = try #require(try RequestMapping.request(
            for: RunWork(route: route(.imageEdit), spec: edit, seed: 1, width: nil, height: nil,
                         inputs: ["images": [Image(format: .png, data: Data(), width: 64, height: 64)]])) as? IEditRequest)
        #expect(editing.metaData["upsample"] == .bool(true))
        #expect(editing.metaData["strength"] == .double(0.5), "the mapping's own keys still ride along")

        let plain = try #require(try RequestMapping.request(
            for: RunWork(route: route(.textToImage), spec: JobSpec(capability: .textToImage, params: ["prompt": "x"]),
                         seed: 1, width: 1024, height: 1024)) as? T2IRequest)
        #expect(plain.metaData.isEmpty)
    }

    @Test("Undeclared package keys and wrong types are refused at submit and when mapping, never dropped")
    func metaDataRefusals() throws {
        let flux3 = RoutedModel(id: ModelID("flux-3-klein"), packageID: "imgsrv.flux-3-klein", capability: .textToImage,
                                displayName: "FLUX 3 Klein",
                                license: LicenseStamp(licenseClass: .restricted, weightLicenses: [], portCodeLicense: "MIT"),
                                envelope: SizeEnvelope(maxPixels: 2048 * 2048, multipleOf: 16),
                                defaults: GenerationDefaults(steps: 16, guidance: 1), sourceRepo: "", revision: "",
                                requestKeys: ModelCatalog.flux3RequestKeys)
        var bare = flux3
        bare.requestKeys = []
        func spec(_ meta: JSONObject) -> JobSpec { JobSpec(capability: .textToImage, params: ["prompt": "x"], metaData: meta) }

        #expect(throws: Never.self) { _ = try SubmitValidation.validate(spec(["upsample": false]), route: flux3) }
        // Adapters wait for the typed contract (AB-D-0155): Qwen Flash's free-form `loras` is not a request key.
        do {
            _ = try SubmitValidation.validate(spec(["loras": [["repo": "a/b", "file": "c.safetensors"]]]), route: flux3)
            Issue.record("an undeclared key passed")
        } catch let error as APIError {
            #expect(error.status == 422 && error.code == "unsupported_parameter" && error.param == "meta_data.loras")
            #expect(error.message.contains("takes only upsample, boxes"))
        }
        do {
            _ = try SubmitValidation.validate(spec(["upsample": "no"]), route: flux3)
            Issue.record("a string passed for a bool key")
        } catch let error as APIError {
            #expect(error.code == "param_out_of_range" && error.param == "meta_data.upsample")
        }
        #expect(throws: APIError.self) { _ = try SubmitValidation.validate(spec(["think": true]), route: bare) }
        #expect(throws: Never.self) { _ = try SubmitValidation.validate(spec(["think": nil]), route: bare) }
        // A host that builds RunWork itself (the Image Engine) gets the same check from the mapping.
        #expect(throws: JobError.self) {
            _ = try RequestMapping.request(for: RunWork(route: bare, spec: spec(["upsample": false]), seed: 1,
                                                        width: 1024, height: 1024))
        }
    }

    @Test("Which models declare which keys: FLUX 3 Klein upsample + boxes, SenseNova think (T2I on base tiers only)")
    func requestKeyDeclarations() throws {
        let all = ModelCatalog.all(environment: [:])
        let flux3 = try #require(all.first { $0.id == "flux-3-klein" })
        #expect(flux3.requestKeys.map(\.name) == ["upsample", "boxes"])
        #expect(flux3.requestKeys.allSatisfy { Set($0.capabilities) == [.textToImage, .imageEdit] })
        let base = try #require(all.first { $0.id == "sensenova-u1" })
        #expect(base.requestKeys.map(\.name) == ["think"] && Set(base.requestKeys[0].capabilities) == [.textToImage, .imageAnalysis])
        let fast = try #require(all.first { $0.id == "sensenova-u1-fast" })
        #expect(fast.requestKeys.first?.capabilities == [.imageAnalysis], "the distilled tiers refuse think on T2I")
        #expect(all.filter { !$0.requestKeys.isEmpty }.map(\.id.rawValue).sorted()
                == ["flux-3-klein", "sensenova-u1", "sensenova-u1-fast", "sensenova-u1-fast-v1"])
    }

    @Test("JobSpec carries meta_data on the wire; a spec without it decodes and encodes as before")
    func metaDataWire() throws {
        let json = #"{"capability":"textToImage","params":{"prompt":"x"},"meta_data":{"upsample":false,"boxes":[]}}"#
        let spec = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        #expect(spec.metaData == ["upsample": false, "boxes": []])
        let again = try JSONDecoder().decode(JobSpec.self, from: try JSONEncoder().encode(spec))
        #expect(again == spec)
        let old = try JSONDecoder().decode(JobSpec.self, from: Data(#"{"capability":"textToImage"}"#.utf8))
        #expect(old.metaData == nil)
        let encoded = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!encoded.contains("meta_data"), "a spec without keys stores no meta_data")
    }

    @Test("Mage-Flow-Edit's residency follows the Mac: below 32 GB the conditioner and DiT take turns; MLXIMG_MAGE_RESIDENCY overrides")
    func mageResidency() {
        #expect(ModelCatalog.mageResidency([:], physicalMemory: 16 << 30) == .evictAll)
        #expect(ModelCatalog.mageResidency([:], physicalMemory: 24 << 30) == .evictAll)
        #expect(ModelCatalog.mageResidency([:], physicalMemory: 32 << 30) == .resident)
        #expect(ModelCatalog.mageResidency([:], physicalMemory: 128 << 30) == .resident)
        #expect(ModelCatalog.mageResidency(["MLXIMG_MAGE_RESIDENCY": "evict-all"], physicalMemory: 128 << 30) == .evictAll)
        #expect(ModelCatalog.mageResidency(["MLXIMG_MAGE_RESIDENCY": "Evict-Conditioner"], physicalMemory: 128 << 30) == .evictConditioner)
        #expect(ModelCatalog.mageResidency(["MLXIMG_MAGE_RESIDENCY": "resident"], physicalMemory: 16 << 30) == .resident)
        #expect(ModelCatalog.mageResidency(["MLXIMG_MAGE_RESIDENCY": "bogus"], physicalMemory: 16 << 30) == .evictAll)
        let light = ModelCatalog.all(environment: ["MLXIMG_MAGE_RESIDENCY": "evict-all"]).first { $0.id == "mage-flow-edit-turbo" }
        #expect(light?.summary.contains("small-Mac residency") == true)
        let resident = ModelCatalog.all(environment: ["MLXIMG_MAGE_RESIDENCY": "resident"]).first { $0.id == "mage-flow-edit-turbo" }
        #expect(resident?.summary.contains("small-Mac residency") == false)
    }

    @Test("MemoryFit: a projected peak within the budget fits the Mac once idle models are released")
    func memoryFitBudget() {
        #expect(MemoryFit(fits: false, additionalBytes: 0, availableBytes: 0, message: "").fitsBudget == nil)
        #expect(MemoryFit(fits: false, additionalBytes: 0, availableBytes: 0, message: "",
                          projectedPeakBytes: 9_700_000_000, budgetBytes: 12_700_000_000).fitsBudget == true)
        #expect(MemoryFit(fits: true, additionalBytes: 0, availableBytes: 0, message: "",
                          projectedPeakBytes: 17_100_000_000, budgetBytes: 12_700_000_000).fitsBudget == false)
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
        let anime4k = route("anime4k-upscale", package("anime4k-upscale"))
        #expect(EngineRunner.tier(for: anime4k) == .instant)
        #expect(throws: Never.self) { _ = try SubmitValidation.validate(spec(6), route: anime4k) }
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
