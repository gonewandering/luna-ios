import Foundation

/// Groups Live transcript fragments into user and Luna turns. The Live API
/// sends only `session.*_transcript.delta` events (no turn-complete marker), so
/// segmentation is local: a turn closes when the speaker changes, when a
/// backend delegation starts (the user's request is complete), or after a
/// pause longer than `gap`. Fragments are joined exactly as received.
@MainActor final class VoiceTurnSegmenter {
    struct Turn: Equatable {
        let id: String
        let role: String            // "user" or "assistant"
        var text: String
        var startMs: Double
        var endMs: Double
        var closed = false
    }
    let gap: Double
    private(set) var open: Turn?
    private var counter = 0
    private let prefix: String
    /// Called on every change; `closed` is true once the turn will not grow.
    var onTurn: ((Turn) -> Void)?

    init(prefix: String, gap: Double = 1_500) { self.prefix = prefix; self.gap = gap }

    func delta(role: String, text: String, startMs: Double?, endMs: Double?) {
        let start = startMs ?? open?.endMs ?? 0
        let end = max(endMs ?? start, start)
        if var current = open {
            if current.role != role || start - current.endMs > gap { close() }
            else {
                current.text += text; current.endMs = max(current.endMs, end)
                open = current; onTurn?(current); return
            }
        }
        counter += 1
        let turn = Turn(id: prefix + "-\(role)-\(counter)", role: role, text: text, startMs: start, endMs: end)
        open = turn; onTurn?(turn)
    }
    /// Close the open turn, if any, and report it as final.
    func close() {
        guard var current = open else { return }
        current.closed = true; open = nil
        onTurn?(current)
    }
    /// Delegation means the user's utterance is complete; the current user turn
    /// is closed and returned so backend work can be tied to it.
    @discardableResult func delegationStarted() -> Turn? {
        guard let current = open, current.role == "user" else { return lastUser }
        close(); lastUser = current; return current
    }
    private(set) var lastUser: Turn?
    var currentUserTurnID: String? { (open?.role == "user" ? open : lastUser)?.id }
}
