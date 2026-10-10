import Foundation

/// A job's run as a fixed plan of stages, for steppers (console, menu bar): known before the run, advanced by job
/// state. Counters are text — phases take wildly different time, so no overall percentage is ever synthesised.
public enum JobStage: Int, CaseIterable, Sendable {
    case queued, starting, loading, running, storing

    public var title: String {
        switch self {
        case .queued: "Queued"
        case .starting: "Starting"
        case .loading: "Loading model"
        case .running: "Running"
        case .storing: "Storing"
        }
    }

    public var detail: String {
        switch self {
        case .queued: "Waiting its turn behind other jobs."
        case .starting: "Chosen to run next; checking memory."
        case .loading: "Downloading (first use only) and loading the weights."
        case .running: "The model is working."
        case .storing: "Encoding outputs and filing them in the library."
        }
    }
}

extension JobSnapshot {
    /// Where the job is in `JobStage.allCases`: a stage, `allCases.count` once it succeeded, nil if it failed or
    /// was cancelled (those render as an outcome, not a position).
    public var stageIndex: Int? {
        switch state {
        case .queued: JobStage.queued.rawValue
        case .admitted: JobStage.starting.rawValue
        case .preparing: JobStage.loading.rawValue
        case .running: JobStage.running.rawValue
        case .finishing: JobStage.storing.rawValue
        case .succeeded: JobStage.allCases.count
        case .failed, .cancelled: nil
        }
    }

    /// The live counter for the current stage, pre-formatted ("denoise 5/8 · image 2 of 4",
    /// "downloading 42% · 35.2 MB/s", "requeued 1/2", "#3 in queue"). nil when there is nothing true to say.
    public var stageCounter: String? {
        switch state {
        case .queued:
            return queuePosition.map { "#\($0) in queue" }
        case .admitted:
            return progress?.phase == "waiting_for_memory" ? "waiting for memory to free up" : nil
        case .preparing:
            guard let p = progress else { return nil }
            var text = p.phase
            if let f = p.fraction, f > 0 { text += " \(Int((f * 100).rounded()))%" }
            if let bps = p.bytesPerSecond, bps > 0 { text += String(format: " · %.1f MB/s", bps / 1_000_000) }
            return text
        case .running:
            var parts: [String] = []
            if let p = progress {
                parts.append(p.phase == "requeued"
                    ? "preempted, requeued" + (p.step.map { s in p.totalSteps.map { " \(s)/\($0)" } ?? " \(s)" } ?? "")
                    : p.summary)
            }
            if spec.count > 1 {
                parts.append("image \((progress?.outputIndex ?? 0) + 1) of \(spec.count)")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .finishing:
            return spec.count > 1 ? "\(spec.count) outputs" : nil
        case .succeeded, .failed, .cancelled:
            return nil
        }
    }
}
