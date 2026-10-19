import Foundation
import ImageServerAPI
import ImageServerCatalog
@testable import ImageServerModels
import MLXToolKit
import Testing

// End to end through the runtime (AB-A-0191, L1–L3): a catalog adapter named on a job routes to its base model, the
// engine fetches the pinned file into the models root and checks its sha256, the package applies it, and the render
// changes. Live: needs the FLUX.2 Klein snapshot and the network.
//   MLXIMG_ADAPTER_LIVE=1 [MLXIMG_MODELS_ROOT=<models root>] [MLXIMG_ADAPTER_IMAGE=<png>] swift test --filter "Adapters live"
// The adapter downloads into a temporary models root (the Klein snapshot is linked in), not the shared folder.
@Suite("Adapters live", .serialized)
struct AdapterLiveTests {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    @Test("A klein adapter on a job: routed, fetched and verified by the engine, applied, render changed",
          .enabled("MLXIMG_ADAPTER_LIVE=1") { env["MLXIMG_ADAPTER_LIVE"] == "1" })
    @MainActor
    func kleinAdapterEndToEnd() async throws {
        let shared = URL(fileURLWithPath: Self.env["MLXIMG_MODELS_ROOT"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MLXEngine/Models").path)
        let snapshot = shared.appendingPathComponent("models--mlx-community--FLUX.2-klein-4B-bf16")
        try #require(FileManager.default.fileExists(atPath: snapshot.path), "no klein snapshot at \(snapshot.path)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(snapshot.lastPathComponent),
                                                   withDestinationURL: snapshot)

        let catalog = ModelCatalog.all(environment: [:]).filter { ["z-image-turbo", "klein-4b"].contains($0.id.rawValue) }
        let (service, forge) = await ImageEngineService.bootstrap(storeRoot: root, catalog: catalog,
                                                                  adapters: ModelCatalog.adapters())
        _ = forge
        let id = "flux2-klein:background-remove"
        let route = try await service.route(.imageEdit, model: nil, adapters: [id])
        #expect(route.id == "klein-4b", "the adapter implies its base model")
        #expect(await service.adapterDownloadCheck([id]).totalBytes == 76_039_072)

        let imagePath = Self.env["MLXIMG_ADAPTER_IMAGE"]
            ?? "/Volumes/Satechi/Development/WardrobeLoRADev/dataset-tryon-v2/train/targets/px_32003375.png"
        let image = MLXToolKit.Image(format: .png, data: try Data(contentsOf: URL(fileURLWithPath: imagePath)),
                                     width: 1024, height: 1024)
        func spec(_ adapters: [JobAdapter]) -> JobSpec {
            JobSpec(capability: .imageEdit, model: route.id, params: ["prompt": "Remove the background from the image"],
                    inputs: ["images": [AssetID(rawValue: "ast_live")]], adapters: adapters)
        }
        let withAdapter = spec([JobAdapter(id: id)])
        let resolved = try SubmitValidation.validate(withAdapter, route: route)
        let runner = EngineRunner(engine: service.engine)
        try await runner.prepare(route) { _ in }
        func render(_ s: JobSpec) async throws -> Data {
            let out = try await runner.run(RunWork(route: route, spec: s, seed: 42, width: 1024, height: 1024,
                                                   inputs: ["images": [image]])) { _ in }
            guard case .image(let img) = out else { throw JobError(code: "x", message: "not an image") }
            return img.data
        }
        _ = resolved
        let adapted = try await render(withAdapter)
        let plain = try await render(spec([]))
        #expect(adapted != plain, "the adapter changed nothing")
        let sha = try #require(route.adapters.first { $0.id == id }).source.sha256
        let dir = root.appendingPathComponent("adapters").appendingPathComponent(sha)
        #expect(FileManager.default.fileExists(atPath: dir.path), "the engine stores the verified file by digest")
        #expect(await service.engine.adapterNeedsDownload(id: id) == false)
        try? adapted.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("adapter-live-klein.png"))
        await runner.evict(packageID: route.packageID)
    }
}
