import Foundation
import Observation

/// Presentation only: hiding a notice never changes a task or its recovery state.
@MainActor @Observable final class TransientNotices {
    private(set) var deadlines: [String: Date] = [:]
    @ObservationIgnored private var expirationTask: Task<Void, Never>?

    static func run(_ id: String) -> String { "run:" + id }
    static func activity(_ sessionID: String) -> String { "activity:" + sessionID }

    func contains(_ id: String) -> Bool { deadlines[id] != nil }

    func show(_ id: String, duration: TimeInterval = 8, now: Date = Date()) {
        deadlines[id] = now.addingTimeInterval(duration)
        scheduleExpiration()
    }

    func dismiss(_ id: String) {
        guard deadlines.removeValue(forKey: id) != nil else { return }
        scheduleExpiration()
    }

    func removeAll() {
        expirationTask?.cancel(); expirationTask = nil
        deadlines = [:]
    }

    func expire(at now: Date = Date()) {
        deadlines = deadlines.filter { $0.value > now }
        scheduleExpiration()
    }

    private func scheduleExpiration() {
        expirationTask?.cancel(); expirationTask = nil
        guard let deadline = deadlines.values.min() else { return }
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            self?.expire()
        }
    }
}
