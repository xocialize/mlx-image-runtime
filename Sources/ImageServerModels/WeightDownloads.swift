import Foundation
import ImageServerAPI
import MLXHubMetadata
import MLXServeCore
import MLXToolKit
import OSLog

private let log = Logger(subsystem: "com.xocialize.mlx-image-server", category: "weights")

/// What a model still has to download before it can load: each missing weight source, listed and sized on the hub.
/// Nothing is downloaded to find this out (it is the engine's MS-3 preview).
public struct PendingDownload: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        public let role: String
        public let repo: String
        /// The size of the files the source would fetch. nil when the hub couldn't list the repo: no such repo or
        /// revision, a private or gated one, or no network. 0 when the listing had nothing matching its globs.
        public let bytes: UInt64?

        public init(role: String, repo: String, bytes: UInt64?) {
            self.role = role
            self.repo = repo
            self.bytes = bytes
        }

        public var label: String { "\(repo) (\(role))" }
    }

    public let model: ModelID
    /// Only the missing sources. Empty when everything is already in the models folder.
    public let sources: [Source]
    /// Free space on the models folder's volume, when known.
    public let freeBytes: UInt64?

    public init(model: ModelID, sources: [Source], freeBytes: UInt64?) {
        self.model = model
        self.sources = sources
        self.freeBytes = freeBytes
    }

    init(model: ModelID, preview: MaterializationPreview) {
        self.init(model: model,
                  sources: preview.sources.map { Source(role: $0.role, repo: $0.repo, bytes: $0.expectedBytes) },
                  freeBytes: preview.freeBytes)
    }

    /// The sources whose download would fail before a byte arrives: the hub couldn't list them, or nothing in the
    /// listing matched their globs.
    public var unresolved: [Source] { sources.filter { ($0.bytes ?? 0) == 0 } }

    public var totalBytes: UInt64? {
        sources.reduce(UInt64?(0)) { sum, source in sum.flatMap { s in source.bytes.map { s + $0 } } }
    }
}

/// What a model's first use would download, checked without downloading anything.
public enum DownloadCheck: Sendable, Equatable {
    /// Nothing to download: a local snapshot, weights bundled in the binary, or already in the models folder.
    case present
    /// The weight sources the engine would download, each sized on the hub.
    case pending(PendingDownload)
    /// The package downloads its own weights inside `load()`, through a hub client the engine can't see, so there is
    /// nothing to check until it runs.
    case opaque
}

extension ImageEngineService {
    /// What `id` would download on first use (see `DownloadCheck`). nil when the model isn't registered.
    public func downloadCheck(_ id: ModelID) async -> DownloadCheck? {
        guard let entry = entries.first(where: { $0.id == id }), let capability = entry.capabilities.first,
              let registration = await registeredModels().first(where: { $0.id == id }) else { return nil }
        if entry.localSnapshot != nil { return .present }
        let package = PackageID(registration.packageID)
        if let preview = await engine.materializationPreview(capability, package: package) {
            return preview.isSatisfied ? .present : .pending(PendingDownload(model: id, preview: preview))
        }
        return await engine.needsDownload(capability, package: package) ? .opaque : .present
    }
}

/// A model's weights failed to download: which repos, and what the hub said (AB-T-0221).
///
/// The engine's own errors name neither. A repo that was never published failed its file listing as
/// `httpStatus(404)`, which reads the same as an outage. `EngineRunner.prepare` throws this instead, naming the
/// sources the hub couldn't list, or else every source that was still missing.
public struct WeightDownloadError: Error, LocalizedError, CustomStringConvertible {
    public let model: ModelID
    public let sources: [PendingDownload.Source]
    public let underlying: any Error

    public init(model: ModelID, sources: [PendingDownload.Source], underlying: any Error) {
        self.model = model
        self.sources = sources
        self.underlying = underlying
    }

    public var description: String {
        let from = sources.isEmpty ? "" : " from " + sources.map(\.label).joined(separator: ", ")
        let reason = Self.reason(underlying)
        return "Downloading weights for \(model.rawValue)\(from) failed: \(reason)" + (reason.hasSuffix(".") ? "" : ".")
    }

    public var errorDescription: String? { description }

    static func reason(_ error: any Error) -> String {
        switch error {
        case let error as HubMetadataError:
            switch error {
            case .httpStatus(let code) where code == 401 || code == 404:
                // The hub answers 401 anonymously and 404 with a token for a repo it won't list.
                return "the hub has no such repo or revision, or it is private or gated (HTTP \(code) on its file listing)"
            case .httpStatus(let code): return "HTTP \(code) on the hub's file listing"
            case .unauthorized: return "the hub rejected the access token"
            case .noToken: return "no hub access token"
            case .malformedResponse: return "the hub's file listing was unreadable"
            }
        case let error as WeightMaterializer.MaterializeError:
            return error.errorDescription ?? "\(error)"
        case let error as URLError:
            return error.localizedDescription
        default:
            return "\(error)"
        }
    }

    /// Whether `error` came from downloading: the hub listing, the transfer, or the network under either.
    static func isDownloadFailure(_ error: any Error) -> Bool {
        switch error {
        case is HubMetadataError, is WeightMaterializer.MaterializeError: return true
        case let error as URLError: return error.code != .cancelled
        default: return false
        }
    }

    /// `error` with the sources it concerns, from the engine's preview of what `package` still needs. A listing
    /// failure names the sources the hub couldn't list (the preview asks the hub again); anything else names every
    /// missing source.
    static func describing(_ error: any Error, model: ModelID, engine: MLXServeEngine, capability: Capability,
                           package: PackageID) async -> WeightDownloadError {
        let missing = await engine.materializationPreview(capability, package: package)
            .map { PendingDownload(model: model, preview: $0).sources } ?? []
        let unlisted = missing.filter { $0.bytes == nil }
        let sources = error is HubMetadataError && !unlisted.isEmpty ? unlisted : missing
        let failure = WeightDownloadError(model: model, sources: sources, underlying: error)
        log.error("\(failure.description, privacy: .public)")
        return failure
    }
}
