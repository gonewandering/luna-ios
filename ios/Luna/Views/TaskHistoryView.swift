import SwiftUI

/// Retains access to error details after their temporary notices disappear.
struct TaskHistoryView: View {
    @Bindable var store: AppStore
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    private var runs: [AgentRun] {
        store.runs.values.filter { $0.sessionID == sessionID }.sorted { $0.created > $1.created }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(run.statusLabel).font(.caption.weight(.semibold)).foregroundStyle(Palette.forest)
                            Spacer()
                            Text(Date(timeIntervalSince1970: run.created), style: .relative)
                                .font(.caption2).foregroundStyle(Palette.muted)
                        }
                        Text(run.text).font(.callout).textSelection(.enabled)
                        if let error = run.error {
                            Text(error).font(.caption).foregroundStyle(Palette.orange).textSelection(.enabled)
                        }
                        if let decision = run.modelDecision {
                            Text("Auto requested " + decision.selection.model).font(.caption).foregroundStyle(Palette.muted)
                            Text(decision.reason).font(.caption).foregroundStyle(Palette.muted)
                        }
                        if run.status == "unknown" && run.historyReconciled != true {
                            Text("Check this conversation with the agent before allowing more work in this session.")
                                .font(.caption).foregroundStyle(Palette.muted)
                            Button("I checked the agent · allow new tasks") { store.acknowledgeUnknown(run.id) }
                                .font(.callout)
                        }
                    }.padding(.vertical, 6).listRowBackground(Palette.card)
                }
            }
            .overlay {
                if runs.isEmpty { ContentUnavailableView("No tasks yet", systemImage: "clock") }
            }
            .scrollContentBackground(.hidden).background(Palette.canvas)
            .foregroundStyle(Palette.ink)
            .navigationTitle("Task history").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
