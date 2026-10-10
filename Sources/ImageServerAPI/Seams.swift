import Foundation
import MLXToolKit

/// An error in API shape. The HTTP layer renders it as `{"error":{type,code,message,param}}` with `status`;
/// MCP renders it as an `isError` tool result carrying `code`.
public struct APIError: Error, Sendable, Equatable, Codable {
    public var status: Int
    public var type: String
    public var code: String
    public var message: String
    public var param: String?

    public init(status: Int, type: String = "invalid_request_error", code: String, message: String, param: String? = nil) {
        self.status = status
        self.type = type
        self.code = code
        self.message = message
        self.param = param
    }

    public static func badRequest(_ code: String, _ message: String, param: String? = nil) -> APIError {
        APIError(status: 400, code: code, message: message, param: param)
    }
    public static func unprocessable(_ code: String, _ message: String, param: String? = nil) -> APIError {
        APIError(status: 422, code: code, message: message, param: param)
    }
    public static func notFound(_ message: String) -> APIError {
        APIError(status: 404, code: "not_found", message: message)
    }
    public static func conflict(_ code: String, _ message: String) -> APIError {
        APIError(status: 409, code: code, message: message)
    }
    public static func tooManyRequests(_ message: String) -> APIError {
        APIError(status: 429, type: "rate_limit_error", code: "queue_full", message: message)
    }
    public static func unavailable(_ message: String) -> APIError {
        APIError(status: 503, type: "server_error", code: "engine_unavailable", message: message)
    }
}

/// The job queue as the wire layers see it. Implemented by `ImageServerCore.JobScheduler`.
public protocol ImageJobQueue: Sendable {
    /// Validates, routes and enqueues. Throws `APIError` for anything the caller can fix.
    func submit(_ spec: JobSpec, origin: JobOrigin, client: ClientID, idempotencyKey: String?) async throws -> JobSnapshot
    /// Resolves a spec exactly as `submit` would (route, brand, size, warnings) without enqueuing it.
    func preview(_ spec: JobSpec) async throws -> JobPreview
    /// Queues describe jobs for assets (a few at a time; the rest wait in a backlog).
    func describe(_ assets: [AssetID], options: DescribeOptions, origin: JobOrigin, client: ClientID) async throws
        -> DescribeBatch
    /// Describes new assets if auto-describe is on for `trigger`; a no-op otherwise. Never throws.
    func autoDescribe(_ assets: [AssetID], trigger: DescribeTrigger, origin: JobOrigin, client: ClientID) async
    func autoDescribeSettings() async -> AutoDescribeSettings
    /// Validates (the model must route for imageAnalysis) and persists.
    func setAutoDescribeSettings(_ settings: AutoDescribeSettings) async throws
    func cancel(_ id: JobID) async -> CancelOutcome
    func job(_ id: JobID) async -> JobSnapshot?
    func list(limit: Int, states: Set<JobState>?) async -> [JobSnapshot]
    /// Replays the current snapshot first, then live events; finishes after the terminal event.
    func events(for id: JobID) async -> AsyncStream<JobEvent>
    /// Every job's events, live only.
    func events() async -> AsyncStream<JobEvent>
    /// Returns as soon as the job is terminal, or the latest snapshot at the deadline. Never awaits a `Task.value`.
    func wait(_ id: JobID, timeout: Duration) async -> JobSnapshot?
    func status() async -> QueueStatus
    func setPaused(_ paused: Bool) async
}

/// Residency as the queue manages it: which models are loaded, which are pinned, and when idle ones unload.
public struct ModelResidency: Sendable, Codable, Equatable {
    public var model: ModelID
    public var resident: Bool
    public var pinned: Bool
    /// When an idle resident model will be unloaded (nil when pinned, busy, or not resident).
    public var evictsAt: Date?

    public init(model: ModelID, resident: Bool, pinned: Bool, evictsAt: Date?) {
        self.model = model
        self.resident = resident
        self.pinned = pinned
        self.evictsAt = evictsAt
    }

    enum CodingKeys: String, CodingKey {
        case model, resident, pinned
        case evictsAt = "evicts_at"
    }
}

/// Model lifecycle through the queue — so a load or unload never races a running job. Implemented by `JobScheduler`.
public protocol ModelResidencyControl: Sendable {
    /// Queues a prepare-only job (download + load).
    func prepare(_ model: ModelID, client: ClientID) async throws -> JobSnapshot
    /// Unloads now. Throws 409 if a job is running on it.
    func evict(_ model: ModelID) async throws
    /// A pinned model is never unloaded for being idle (it can still be swapped out when another model needs memory).
    func setPinned(_ model: ModelID, _ pinned: Bool) async throws
    func residency() async -> [ModelResidency]
}

/// The model catalog as the wire layers see it. Implemented by `ImageServerCore.ImageEngineService`.
public protocol ImageModelDirectory: Sendable {
    func models() async -> [ModelInfo]
    func model(_ id: ModelID) async -> ModelInfo?
    /// Capabilities with at least one registered model, in a stable order.
    func capabilities() async -> [Capability]
}
