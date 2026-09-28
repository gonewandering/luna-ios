import Foundation

/// Translates one agent's run lifecycle into transcript entries. Every write
/// is keyed by run ID so repeated snapshots update rows instead of duplicating
/// them. Tool events keep a per-run ordinal so the same tool used twice yields
/// two rows. The recorder never contacts an agent.
@MainActor final class TranscriptRecorder {
    let store: TranscriptStore
    let agentID: String
    var agentName: () -> String
    private var openTools: [String: [String]] = [:]   // runID → open tool entry IDs, in order
    private var toolCounts: [String: Int] = [:]

    init(store: TranscriptStore, agentID: String, agentName: @escaping () -> String) {
        self.store = store; self.agentID = agentID; self.agentName = agentName
    }

    static func promptID(_ runID: String) -> String { runID + "-prompt" }
    static func outputID(_ runID: String) -> String { runID + "-output" }

    /// A run was admitted or changed. The prompt row is written once; the
    /// output row follows the run's text and status.
    func record(_ run: AgentRun, previous: AgentRun?) {
        let address = SessionAddress(agentID: agentID, sessionID: run.sessionID)
        let turn = run.turnID ?? "run-" + run.id
        do {
            if previous == nil, try store.entry(Self.promptID(run.id)) == nil {
                try store.upsert(TranscriptEntry(id: Self.promptID(run.id), turnID: turn, address: address, kind: .lunaToAgent, text: run.text,
                                                 runID: run.id, upstreamID: run.upstreamID, agentName: agentName(), photos: run.photos,
                                                 createdAt: run.created))
                if run.turnID != nil { try store.attach(turn: turn, to: address) }
            } else if let upstream = run.upstreamID, previous?.upstreamID == nil, var prompt = try store.entry(Self.promptID(run.id)) {
                prompt.upstreamID = upstream
                try store.upsert(prompt)
            }
            let hasOutput = !run.output.isEmpty || run.error != nil
            guard hasOutput || !run.isActive else { return }
            let status: TranscriptEntry.Status = run.isActive ? .streaming : run.status == "completed" ? .final
                : run.status == "cancelled" || run.status == "interrupted" ? .partial : .failed
            let existing = try store.entry(Self.outputID(run.id))
            if !hasOutput && existing == nil { return }
            // Output takes its place when it first appears, so tool rows that
            // arrived earlier stay above it.
            var output = existing ?? TranscriptEntry(id: Self.outputID(run.id), turnID: turn, address: address, kind: .agentFinal, text: "",
                                                     runID: run.id, agentName: agentName(), createdAt: max(run.created + 0.001, Date().timeIntervalSince1970))
            output.text = run.output.isEmpty ? (run.error ?? "") : run.output
            output.status = status; output.upstreamID = run.upstreamID
            if run.isActive { store.stage(output) }
            else {
                try store.upsert(output)
                closeTools(run.id, failed: run.status != "completed")
            }
        } catch { /* Transcript writes never block the run itself. */ }
    }

    /// A tool or subagent event for a run. Started events open a row; finished
    /// events close the most recent open row with the same title.
    func record(event: HermesEvent, runID: String, sessionID: String) {
        guard event.type.hasPrefix("tool.") || event.type.hasPrefix("subagent.") else { return }
        let title = event.data["tool"]?.string ?? event.data["name"]?.string ?? "Agent tool"
        let preview = event.data["preview"]?.string ?? ""
        let finished = !event.type.hasSuffix("started")
        let failed = event.type.hasSuffix("failed") || event.data["error"]?.bool == true
        let arguments = Self.detail(event.data, keys: ["arguments", "args", "input", "command"])
        let result = Self.detail(event.data, keys: ["result", "output", "response"])
        do {
            if !finished || openTools[runID]?.isEmpty != false {
                if finished, let id = openTools[runID]?.last, var open = try store.entry(id), open.tool?.name == title {
                    open.tool?.status = failed ? "failed" : "completed"; open.tool?.result = result.isEmpty ? preview : result
                    try store.upsert(open); openTools[runID]?.removeLast(); return
                }
                let ordinal = (toolCounts[runID] ?? 0) + 1; toolCounts[runID] = ordinal
                let turn = try store.entry(Self.promptID(runID))?.turnID ?? "run-" + runID
                let entry = TranscriptEntry(id: runID + "-tool-\(ordinal)", turnID: turn, address: SessionAddress(agentID: agentID, sessionID: sessionID),
                                            kind: .agentTool, text: preview,
                                            tool: .init(name: title, arguments: arguments.isEmpty ? preview : arguments, result: finished ? (result.isEmpty ? preview : result) : "",
                                                        status: finished ? (failed ? "failed" : "completed") : "running"),
                                            runID: runID, agentName: agentName(), status: finished ? (failed ? .failed : .final) : .streaming,
                                            createdAt: Date().timeIntervalSince1970)
                try store.upsert(entry)
                if !finished { openTools[runID, default: []].append(entry.id) }
            } else if let index = openTools[runID]?.lastIndex(where: { (try? store.entry($0))??.tool?.name == title }) ?? openTools[runID]?.indices.last,
                      let id = openTools[runID]?[index], var open = try store.entry(id) {
                open.tool?.status = failed ? "failed" : "completed"
                open.tool?.result = result.isEmpty ? preview : result
                open.text = preview.isEmpty ? open.text : preview
                open.status = failed ? .failed : .final
                try store.upsert(open)
                openTools[runID]?.remove(at: index)
            }
        } catch { }
    }

    private func closeTools(_ runID: String, failed: Bool) {
        for id in openTools[runID] ?? [] {
            guard var open = try? store.entry(id) else { continue }
            open.tool?.status = failed ? "interrupted" : "completed"; open.status = failed ? .partial : .final
            try? store.upsert(open)
        }
        openTools[runID] = nil; toolCounts[runID] = nil
    }

    private static func detail(_ data: JSONObject, keys: [String]) -> String {
        for key in keys {
            guard let value = data[key], value != .null else { continue }
            if let text = value.string { return text }
            if let encoded = try? JSONEncoder().encode(value) { return String(decoding: encoded, as: UTF8.self) }
        }
        return ""
    }

    /// Fold a server history page into the transcript.
    func reconcile(_ history: [ChatMessage], sessionID: String, fallbackTime: Double) {
        let address = SessionAddress(agentID: agentID, sessionID: sessionID)
        guard let existing = try? store.entries(address) else { return }
        let updates = TranscriptReconciliation.merge(history: history, into: existing, address: address, agentName: agentName(), fallbackTime: fallbackTime)
        guard !updates.isEmpty else { return }
        try? store.importOrReplace(updates)
    }
}
