import SwiftUI

/// Renders a session's transcript in chronological order with a distinct style
/// per leg. Agent tool rows are grouped per run; Luna summaries reveal the raw
/// agent output beneath them. Labels use the agent's current saved name.
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    let agentName: String
    /// Entries a `lunaToUser` summary covers are shown collapsed under it.
    private var summarized: Set<String> { Set(entries.flatMap { $0.summarizes ?? [] }) }

    var body: some View {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ForEach(TranscriptView.rows(entries, summarized: summarized)) { row in
            switch row {
            case .single(let entry):
                TranscriptEntryView(entry: entry, agentName: agentName, summarized: entry.summarizes?.compactMap { byID[$0] } ?? [])
                    .id(entry.id)
            case .tools(let id, let tools, let agentTools):
                ToolGroupView(id: id, tools: tools, label: agentTools ? agentName : "Luna").id(id)
            }
        }
    }

    enum Row: Identifiable, Equatable {
        case single(TranscriptEntry)
        case tools(String, [TranscriptEntry], agent: Bool)
        var id: String {
            switch self { case .single(let entry): entry.id; case .tools(let id, _, _): id }
        }
    }

    /// Consecutive tool rows of the same kind and run/turn fold into one group;
    /// summarized raw outputs are hidden as standalone rows.
    static func rows(_ entries: [TranscriptEntry], summarized: Set<String>) -> [Row] {
        var rows: [Row] = []
        for entry in entries where !summarized.contains(entry.id) {
            let isTool = entry.kind == .agentTool || entry.kind == .lunaTool
            if isTool, case .tools(let id, var tools, let agent)? = rows.last, agent == (entry.kind == .agentTool),
               tools.last.map({ ($0.runID ?? $0.turnID) == (entry.runID ?? entry.turnID) }) == true {
                tools.append(entry); rows[rows.count - 1] = .tools(id, tools, agent: agent)
            } else if isTool {
                rows.append(.tools("tools-" + entry.id, [entry], agent: entry.kind == .agentTool))
            } else { rows.append(.single(entry)) }
        }
        return rows
    }
}

enum TranscriptDebug {
    /// Simulator screenshots: open every disclosure so the whole tree is visible.
    static let expandAll: Bool = {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--expand-transcript")
        #else
        false
        #endif
    }()
}

struct TranscriptEntryView: View {
    let entry: TranscriptEntry
    let agentName: String
    var summarized: [TranscriptEntry] = []
    @State private var expanded = TranscriptDebug.expandAll
    @State private var fullPrompt = false
    private var label: String { (entry.agentName?.isEmpty == false && agentName.isEmpty) ? entry.agentName! : agentName }

    var body: some View {
        switch entry.kind {
        case .userToLuna:
            VStack(alignment: .trailing, spacing: 7) {
                Text("YOU" + (entry.source == .spoken ? " · SPOKEN" : entry.source == .typed ? " · TYPED" : ""))
                    .font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.muted)
                ForEach(entry.photos ?? []) { photo in ChatPhotoView(photo: photo) }
                if !entry.text.isEmpty {
                    Text(entry.text).font(.body).textSelection(.enabled).padding(16)
                        .background(Palette.userBubble, in: RoundedRectangle(cornerRadius: 19))
                        .opacity(entry.status == .streaming ? 0.7 : 1)
                }
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 30)
        case .lunaToAgent:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    LunaMark(size: 14)
                    Text("LUNA").font(.system(size: 9, weight: .bold)).tracking(1.4)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                    Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.4).lineLimit(1)
                }.foregroundStyle(Palette.sectionLabel)
                ForEach(entry.photos ?? []) { photo in ChatPhotoView(photo: photo) }
                Text(entry.text).font(.callout).foregroundStyle(Palette.muted).textSelection(.enabled)
                    .lineLimit(fullPrompt ? nil : 4)
                if entry.text.count > 280 {
                    Button(fullPrompt ? "Hide full prompt" : "Show full prompt") { fullPrompt.toggle() }
                        .font(.caption.weight(.medium)).foregroundStyle(Palette.forest)
                }
            }.padding(.vertical, 10).padding(.horizontal, 14)
                .background(Palette.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
                .accessibilityLabel("Luna to " + label + ": " + entry.text)
        case .agentInterim, .agentFinal:
            agentMessage
        case .lunaToUser:
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 7) {
                    LunaMark(size: 22)
                    Text("LUNA" + (entry.source == .spoken ? " · SPOKEN" : "")).font(.system(size: 9, weight: .bold)).tracking(1.4)
                    Spacer()
                    Button { UIPasteboard.general.string = entry.text } label: { Image(systemName: "doc.on.doc").font(.caption) }
                        .foregroundStyle(Palette.muted).accessibilityLabel("Copy Luna's reply")
                }.foregroundStyle(Palette.forest)
                Text(entry.text).font(.system(.body, design: .serif)).textSelection(.enabled)
                    .opacity(entry.status == .streaming ? 0.7 : 1)
                if !summarized.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(summarized) { raw in
                                TranscriptEntryView(entry: raw, agentName: agentName)
                            }
                        }.padding(.top, 12)
                    } label: {
                        Label((expanded ? "Hide " : "View ") + label + "’s full response", systemImage: "text.alignleft")
                            .font(.caption.weight(.medium)).foregroundStyle(Palette.forest)
                    }.tint(Palette.forest)
                }
            }
        case .agentTool, .lunaTool:
            ToolGroupView(id: entry.id, tools: [entry], label: entry.kind == .agentTool ? label : "Luna")
        }
    }

    private var agentMessage: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Circle().fill(Palette.line).frame(width: 22, height: 22)
                    .overlay(Text(String(label.prefix(1)).uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ink))
                Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.4).lineLimit(1)
                if entry.status == .partial { Text("· PARTIAL").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(Palette.orange) }
                if entry.status == .failed { Text("· FAILED").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(Palette.orange) }
                Spacer()
                Button { UIPasteboard.general.string = entry.text } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .foregroundStyle(Palette.muted).accessibilityLabel("Copy response")
            }.foregroundStyle(Palette.forest)
            if entry.status == .failed {
                Text(entry.text).font(.callout).foregroundStyle(Palette.orange).textSelection(.enabled)
            } else {
                RichMessage(text: entry.text).equatable()
            }
            ForEach(entry.photos ?? []) { photo in ChatPhotoView(photo: photo) }
        }
    }
}

/// Tool activity for one run (or one Luna turn). Agent work is shown open, one
/// typed card per call on a thin rail; Luna's own lookups stay a compact,
/// expandable "Luna checked N things" row.
struct ToolGroupView: View {
    let id: String
    let tools: [TranscriptEntry]
    let label: String
    @State private var open = TranscriptDebug.expandAll
    private var active: Bool { tools.contains { $0.tool?.status == "running" } }
    private var failed: Bool { tools.contains { $0.tool?.status == "failed" } }

    var body: some View {
        if label == "Luna" { lunaLookups } else { agentWork }
    }

    private var agentWork: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if active { ProgressView().controlSize(.mini) }
                Text(label.uppercased() + " · \(tools.count) STEP\(tools.count == 1 ? "" : "S")" + (active ? " · WORKING" : ""))
                    .font(.system(size: 9, weight: .bold)).tracking(1.4)
            }.foregroundStyle(failed ? Palette.orange : Palette.sectionLabel)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(tools) { entry in ToolWorkCard(entry: entry).id(entry.id) }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
        }
    }

    private var lunaLookups: some View {
        DisclosureGroup(isExpanded: Binding(get: { open || active }, set: { open = $0 })) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(tools) { entry in ToolWorkCard(entry: entry) }
            }.padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if active { ProgressView().controlSize(.mini) }
                else { Image(systemName: failed ? "exclamationmark.circle" : "magnifyingglass").font(.caption) }
                Text("Luna checked \(tools.count) thing\(tools.count == 1 ? "" : "s")").font(.caption.weight(.medium))
            }.foregroundStyle(failed ? Palette.orange : Palette.sectionLabel)
        }.tint(Palette.sectionLabel).padding(.leading, 4)
    }
}
