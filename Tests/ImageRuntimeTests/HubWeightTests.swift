import Foundation
import ImageServerAPI
import ImageServerCatalog
import ImageServerModels
import MLXToolKit
import Testing

// A clean install's first downloads, checked against the hub: list and size every weight source a prod model would
// fetch into an empty models folder, without downloading. Z-Image Turbo shipped naming a repo that was never
// published, and only a machine without local snapshots could see it (AB-T-0221). Needs the network; skipped when the
// hub can't be reached.
@Suite("Weights on the hub", .serialized)
struct HubWeightTests {
    /// Packages that download their own weights inside `load()` (swift-transformers' `HubApi`) and declare no
    /// `WeightSourcing`, so neither the engine nor this check can see their repos. Shrink it as they adopt engine
    /// materialization; a new entry has to be added here on purpose.
    static let selfFetching: Set<ModelID> = ["nafnet-restore", "ddcolor-colorize", "lama-inpaint"]

    @Test("Every prod model's first download resolves on the hub from an empty models folder",
          .enabled("needs huggingface.co") { await Hub.reachable() })
    @MainActor
    func prodDownloadsResolve() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("hub-weights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store) }

        // No MLXIMG_WEIGHTS_ROOT and no snapshot overrides: what a fresh machine gets.
        let (service, forge) = await ImageEngineService.bootstrap(storeRoot: store, catalog: ModelCatalog.all(environment: [:]))
        var checked: [ModelID] = [], present: [ModelID] = [], opaque: Set<ModelID> = []
        for entry in service.entries where entry.maturity == .prod {
            switch await service.downloadCheck(entry.id) {
            case .pending(let download):
                #expect(download.unresolved.isEmpty, """
                    \(entry.id): the hub can't serve \(download.unresolved.map(\.label).joined(separator: ", ")) \
                    (no listing, or nothing matching the source's globs)
                    """)
                checked.append(entry.id)
            case .present: present.append(entry.id)
            case .opaque: opaque.insert(entry.id)
            case nil: Issue.record("\(entry.id) did not register")
            }
        }
        withExtendedLifetime(forge) {}
        #expect(checked.contains("z-image-turbo"), "the AB-T-0221 regression is checked")
        #expect(opaque.subtracting(Self.selfFetching).isEmpty,
                "fetch weights the engine can't see, so nothing can check them: \(opaque.subtracting(Self.selfFetching).sorted { $0.rawValue < $1.rawValue })")
        print("hub weights: \(checked.count) prod models checked on the hub; \(present.count) need no download "
              + "(\(present.map(\.rawValue).joined(separator: ", "))); unseen self-fetchers: "
              + opaque.map(\.rawValue).sorted().joined(separator: ", "))
    }
}

enum Hub {
    /// Any HTTP answer from the hub counts; a transport error doesn't.
    static func reachable() async -> Bool {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models/mlx-community/Z-Image-Turbo-bf16")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        return (try? await URLSession.shared.data(for: request).1) is HTTPURLResponse
    }
}
