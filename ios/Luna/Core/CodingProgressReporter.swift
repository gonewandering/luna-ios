import Foundation

/// What Luna knows locally about a delegated coding run at one moment. Every
/// field is read from the durable journal and the app's own activity rows, so a
/// progress update never resends work or asks Hermes for a status of its own.
struct CodingProgressSnapshot: Equatable, Sendable {
    let backend: CodingAgentBackend
    let agentName: String
    let sessionID: String
    let sessionTitle: String
    let requestID: String
    let status: String
    let statusLabel: String
    let error: String?
    let output: String
    let latestStep: String?
    let failedStep: String?
    let approval: String?
    let startedAt: Double
    var isActive: Bool { !["completed", "cancelled", "failed", "interrupted", "unknown"].contains(status) }
}

struct CodingProgressUpdate: Equatable, Sendable {
    let sequence: Int
    let elapsed: TimeInterval
    let snapshot: CodingProgressSnapshot
    let message: String
    var isFinal: Bool { !snapshot.isActive }

    /// A short written line for the user. Remote output is quoted as an excerpt,
    /// never treated as an instruction.
    static func message(for snapshot: CodingProgressSnapshot, elapsed: TimeInterval) -> String {
        var parts = ["\(snapshot.backend.label) · \(snapshot.agentName) · \(snapshot.sessionTitle)"]
        let when = elapsedPhrase(elapsed)
        switch snapshot.status {
        case "queued":
            parts.append("Queued on this device \(when); Hermes hasn’t started it yet.")
        case "choosing_model", "submitting":
            parts.append("Sending the task to Hermes (\(when)).")
        case "running":
            parts.append("Working \(when).")
        case "waiting_for_approval":
            parts.append("Blocked \(when): it needs your approval in the app.")
        case "stopping":
            parts.append("Stopping \(when).")
        case "completed":
            parts.append("Finished \(when).")
        case "cancelled":
            parts.append("Cancelled \(when).")
        case "unknown":
            parts.append("Outcome unknown \(when). Check this conversation in Hermes before sending more work.")
        case "interrupted":
            parts.append("Interrupted \(when).")
        default:
            parts.append("\(snapshot.statusLabel) \(when).")
        }
        if let approval = snapshot.approval, !approval.isEmpty {
            parts.append("Approval requested: " + excerpt(approval, limit: 160))
        }
        if let step = snapshot.latestStep, !step.isEmpty { parts.append("Latest step: " + excerpt(step, limit: 80) + ".") }
        if let failed = snapshot.failedStep, !failed.isEmpty { parts.append("A step failed: " + excerpt(failed, limit: 80) + ".") }
        if let error = snapshot.error, !error.isEmpty { parts.append("Error: " + excerpt(error, limit: 200)) }
        let trimmed = snapshot.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if snapshot.isActive { parts.append("No output yet.") }
        } else {
            parts.append("\(trimmed.count) characters so far: “" + excerpt(String(trimmed.suffix(180)), limit: 180) + "”")
        }
        return parts.joined(separator: " ")
    }

    static func elapsedPhrase(_ elapsed: TimeInterval) -> String {
        let seconds = Int(max(0, elapsed).rounded())
        if seconds < 45 { return "just now" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "after \(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60, rest = minutes % 60
        let hourText = "\(hours) hour\(hours == 1 ? "" : "s")"
        return rest == 0 ? "after " + hourText : "after \(hourText) \(rest) minute\(rest == 1 ? "" : "s")"
    }
    private static func excerpt(_ value: String, limit: Int) -> String {
        let clean = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= limit ? clean : String(clean.prefix(limit)) + "…"
    }
}

/// Reports a delegated coding run roughly once a minute until it finishes or
/// fails, so the user is never left in a long silence. The interval, clock and
/// sleep are injected so the cadence is testable without waiting.
@MainActor final class CodingProgressReporter {
    static let defaultInterval: TimeInterval = 60
    let requestID: String
    private let interval: TimeInterval
    private let read: () -> CodingProgressSnapshot?
    private let report: (CodingProgressUpdate) -> Void
    private let now: () -> Date
    private let wait: (TimeInterval) async throws -> Void
    private(set) var sequence = 0
    private(set) var finished = false
    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil && !finished }

    init(requestID: String, interval: TimeInterval = defaultInterval,
         now: @escaping () -> Date = Date.init,
         wait: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         read: @escaping () -> CodingProgressSnapshot?,
         report: @escaping (CodingProgressUpdate) -> Void) {
        self.requestID = requestID; self.interval = interval
        self.now = now; self.wait = wait; self.read = read; self.report = report
    }

    func start() {
        guard task == nil, !finished else { return }
        task = Task { [weak self] in
            while true {
                guard let reporter = self, !Task.isCancelled, !reporter.finished else { return }
                do { try await reporter.wait(reporter.interval) } catch { return }
                guard let live = self, !Task.isCancelled, !live.finished else { return }
                guard let update = live.tick() else { return }
                live.report(update)
            }
        }
    }

    /// One reporting step. Returns nil when there is nothing left to report, so
    /// a vanished run stops the loop instead of repeating a stale update.
    func tick() -> CodingProgressUpdate? {
        guard !finished, let snapshot = read() else { finished = true; return nil }
        sequence += 1
        if !snapshot.isActive { finished = true }
        let elapsed = now().timeIntervalSince1970 - snapshot.startedAt
        return CodingProgressUpdate(sequence: sequence, elapsed: elapsed, snapshot: snapshot,
                                    message: CodingProgressUpdate.message(for: snapshot, elapsed: elapsed))
    }

    /// Report a run that has already ended without waiting for the next tick.
    func finish() {
        guard !finished, let update = tick() else { return }
        finished = true
        task?.cancel(); task = nil
        report(update)
    }

    func stop() {
        task?.cancel(); task = nil
    }
}
