import Foundation
import Synchronization
import ImageServerAPI
import MLXServeCore
import MLXToolKit

/// One engine invocation: a single output of a job.
public struct RunWork: Sendable {
    public var route: RoutedModel
    public var spec: JobSpec
    public var seed: UInt64
    public var width: Int?
    public var height: Int?
    /// Resolved input images by parameter name.
    public var inputs: [String: [Image]]
    public var outputIndex: Int

    public init(route: RoutedModel, spec: JobSpec, seed: UInt64, width: Int?, height: Int?,
                inputs: [String: [Image]] = [:], outputIndex: Int = 0) {
        self.route = route
        self.spec = spec
        self.seed = seed
        self.width = width
        self.height = height
        self.inputs = inputs
        self.outputIndex = outputIndex
    }
}

/// The scheduler's view of the engine. `EngineRunner` is the real one; tests use a fake.
///
/// ⚠️ Cancellation contract: `prepare` and `run` must await the engine **directly** — no `Task {}` in between — so
/// cancelling the scheduler's in-flight task reaches the package's checkpoints (AB-L-0052).
/// What one engine run produced.
public enum RunOutput: Sendable {
    case image(Image)
    case matte(Matte, score: Float?)
    case score(Float, subscores: [String: Float])
    /// imageAnalysis: the model's reply (prose, or the JSON a describe job asks for).
    case text(String)
}

public protocol ModelRunner: Sendable {
    func residentPackages() async -> Set<String>
    func prepare(_ route: RoutedModel, progress: @escaping @Sendable (JobProgress) -> Void) async throws
    func run(_ work: RunWork, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> RunOutput
    func evict(packageID: String) async
    /// Whether loading `route` now would fit the machine's available memory (nil = unknown, proceed).
    func machineFit(_ route: RoutedModel) async -> MemoryFit?
}

/// The engine's machine-level fit check, reduced to what the scheduler acts on.
public struct MemoryFit: Sendable, Equatable {
    public var fits: Bool
    /// What still has to come from the machine between now and the run's peak.
    public var additionalBytes: UInt64
    public var availableBytes: UInt64
    public var message: String

    public init(fits: Bool, additionalBytes: UInt64, availableBytes: UInt64, message: String) {
        self.fits = fits
        self.additionalBytes = additionalBytes
        self.availableBytes = availableBytes
        self.message = message
    }
}

public struct EngineRunner: ModelRunner {
    public let engine: MLXServeEngine

    public init(engine: MLXServeEngine) {
        self.engine = engine
    }

    public func residentPackages() async -> Set<String> {
        Set(await engine.residentPackages.keys.map(\.rawValue))
    }

    public func prepare(_ route: RoutedModel, progress: @escaping @Sendable (JobProgress) -> Void) async throws {
        let packageID = PackageID(route.packageID)
        let poller = await ProgressTap.watchPreparation(engine, route.capability, packageID.rawValue, progress)
        defer { poller.cancel() }
        try await engine.prepareDiscardingPackage(route.capability, package: packageID)
    }

    /// Per-run progress comes from a `RunProgress.sink` bound around `engine.run` (contract 1.51.0): the engine
    /// forwards each package report to it in order, plus `.requeue` when the governor preempts and re-admits the
    /// run. Scoped to this task, so it stays right if the scheduler ever runs more than one job at a time.
    public func run(_ work: RunWork, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> RunOutput {
        let request = try RequestMapping.request(for: work)
        let packageID = PackageID(work.route.packageID)
        let sink = ProgressTap.runSink(outputIndex: work.outputIndex, progress)
        let response = try await RunProgress.$sink.withValue(sink) {
            try await engine.run(request, package: packageID)
        }
        return try RequestMapping.output(from: response)
    }

    public func evict(packageID: String) async {
        await engine.evict(package: PackageID(packageID))
    }

    public func machineFit(_ route: RoutedModel) async -> MemoryFit? {
        guard let advisory = try? await engine.machineFitAdvisory(route.capability, package: PackageID(route.packageID))
        else { return nil }
        return MemoryFit(fits: advisory.fits, additionalBytes: advisory.additionalBytes,
                         availableBytes: advisory.machine.availableBytes, message: advisory.message)
    }
}

extension MLXServeEngine {
    /// `prepare` returns the resident package, which callers outside the engine have no use for (and which must not
    /// cross isolation domains). This keeps the returned value inside the actor.
    func prepareDiscardingPackage(_ capability: Capability, package: PackageID) async throws {
        _ = try await prepare(capability, package: package)
    }
}

/// Engine progress → job progress. Runs report through a caller-bound sink (per run, per task). Preparation is
/// still observed on the engine's `PreparationMonitor` keyed by (capability, package), which is right because
/// the scheduler prepares one package at a time.
enum ProgressTap {
    /// A `RunProgress.Sink` for one output. It runs on the package's run loop, so it only converts and hands off,
    /// and it drops same-phase reports closer than 100 ms apart (a phase change or a phase's last step always
    /// gets through).
    static func runSink(outputIndex: Int, _ progress: @escaping @Sendable (JobProgress) -> Void) -> RunProgress.Sink {
        let last = Mutex<(phase: RunPhase?, at: ContinuousClock.Instant?)>((nil, nil))
        return { report in
            let now = ContinuousClock.now
            let pass = last.withLock { state -> Bool in
                let isLast = report.step != nil && report.step == report.totalSteps
                if state.phase == report.phase, !isLast, let at = state.at, now - at < .milliseconds(100) { return false }
                state = (report.phase, now)
                return true
            }
            guard pass else { return }
            progress(jobProgress(report, outputIndex: outputIndex))
        }
    }

    static func jobProgress(_ report: RunPhaseReport, outputIndex: Int) -> JobProgress {
        // The governor preempted the run; the engine re-admits it from the start (step = requeue ordinal).
        if report.phase == .requeue {
            return JobProgress(phase: "requeued", step: report.step, totalSteps: report.totalSteps,
                               outputIndex: outputIndex)
        }
        let fraction: Double? = {
            guard let step = report.step, let total = report.totalSteps, total > 0 else { return nil }
            return Double(step) / Double(total)
        }()
        return JobProgress(phase: report.phase.rawValue, fraction: fraction, step: report.step,
                           totalSteps: report.totalSteps, stage: report.stage, totalStages: report.totalStages,
                           outputIndex: outputIndex)
    }

    @MainActor
    static func watchPreparation(_ engine: MLXServeEngine, _ capability: Capability, _ packageID: String,
                                 _ progress: @escaping @Sendable (JobProgress) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            var last: PreparePhase?
            while !Task.isCancelled {
                let phase = engine.preparation.phase(for: capability, package: packageID)
                if phase != last {
                    last = phase
                    switch phase {
                    case .downloading(let fraction, let bps):
                        progress(JobProgress(phase: "downloading", fraction: fraction, bytesPerSecond: bps))
                    case .prewarming(let fraction):
                        progress(JobProgress(phase: "loading", fraction: fraction))
                    case .registering, .loading:
                        progress(JobProgress(phase: "loading"))
                    case .idle, .ready, .failed:
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
