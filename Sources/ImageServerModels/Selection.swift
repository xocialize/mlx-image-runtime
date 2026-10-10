import Foundation
import ImageServerAPI

/// Tunables for choosing the next job. Defaults from Docs/PLAN.md (Scheduler).
public struct SchedulingPolicy: Sendable, Equatable {
    /// A job waiting this long is *due*: it runs before any affinity choice.
    public var maxWait: TimeInterval = 300
    /// A job passed over this many times is *due*.
    public var maxBypass = 4
    /// Score bonus for a job whose model is already resident (avoids a 10–40 GB swap).
    public var residentBonus: Double = 120
    /// Score bonus for jobs submitted from the console.
    public var uiBonus: Double = 30
    /// Score per unit of client priority (-1…1).
    public var priorityWeight: Double = 15
    /// After this many consecutive jobs (or seconds) on one package while others wait, switch.
    public var affinityRunLimit = 8
    public var affinityTimeLimit: TimeInterval = 600

    public init() {}
}

/// A queued job as the selector sees it.
public struct SelectionCandidate: Sendable, Equatable {
    public var id: JobID
    public var seq: Int64
    public var packageID: String
    public var enqueuedAt: Date
    public var origin: JobOrigin
    public var priority: Int
    public var bypassCount: Int

    public init(id: JobID, seq: Int64, packageID: String, enqueuedAt: Date, origin: JobOrigin, priority: Int,
                bypassCount: Int) {
        self.id = id
        self.seq = seq
        self.packageID = packageID
        self.enqueuedAt = enqueuedAt
        self.origin = origin
        self.priority = priority
        self.bypassCount = bypassCount
    }
}

/// Consecutive dispatches on one package.
public struct AffinityStreak: Sendable, Equatable {
    public var packageID: String
    public var count: Int
    public var since: Date

    public init(packageID: String, count: Int, since: Date) {
        self.packageID = packageID
        self.count = count
        self.since = since
    }
}

/// Model-affinity with aging. Pure, so its fairness bounds are testable without an engine.
public enum Selection {
    /// Picks the next job, or nil when there are no candidates.
    ///
    /// 1. **Due first.** Any job waiting ≥ `maxWait` or bypassed ≥ `maxBypass` times runs, oldest first.
    /// 2. **Streak limit.** If one package has run `affinityRunLimit` jobs (or `affinityTimeLimit` seconds) in a row
    ///    and other packages are waiting, its jobs sit out this pick.
    /// 3. **Score.** `wait_s + residentBonus·resident + uiBonus·ui + priorityWeight·priority`; ties go to the oldest.
    public static func pick(_ candidates: [SelectionCandidate], resident: Set<String>, streak: AffinityStreak?,
                            now: Date, policy: SchedulingPolicy = SchedulingPolicy()) -> JobID? {
        guard !candidates.isEmpty else { return nil }
        let ordered = candidates.sorted { $0.seq < $1.seq }

        if let due = ordered.first(where: {
            now.timeIntervalSince($0.enqueuedAt) >= policy.maxWait || $0.bypassCount >= policy.maxBypass
        }) {
            return due.id
        }

        var pool = ordered
        if let streak,
           streak.count >= policy.affinityRunLimit || now.timeIntervalSince(streak.since) >= policy.affinityTimeLimit {
            let others = ordered.filter { $0.packageID != streak.packageID }
            if !others.isEmpty { pool = others }
        }

        var best: (candidate: SelectionCandidate, score: Double)?
        for candidate in pool {
            let s = score(candidate, resident: resident, now: now, policy: policy)
            if best == nil || s > best!.score { best = (candidate, s) }   // strict > keeps the oldest on ties
        }
        return best?.candidate.id
    }

    public static func score(_ c: SelectionCandidate, resident: Set<String>, now: Date,
                             policy: SchedulingPolicy) -> Double {
        let wait = max(0, now.timeIntervalSince(c.enqueuedAt))
        let residentBonus = resident.contains(c.packageID) ? policy.residentBonus : 0
        let uiBonus = c.origin == .ui ? policy.uiBonus : 0
        let priority = Double(max(-1, min(1, c.priority))) * policy.priorityWeight
        return wait + residentBonus + uiBonus + priority
    }
}
