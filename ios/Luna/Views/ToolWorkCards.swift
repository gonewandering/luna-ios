import SwiftUI

/// One tool call rendered as the kind of work it was. Cards are open by
/// default; long bodies are clipped with a "Show all" control instead of
/// hiding the whole card.
struct ToolWorkCard: View {
    let entry: TranscriptEntry
    private var tool: TranscriptEntry.ToolCall { entry.tool ?? .init(name: "Tool") }
    private var work: ToolWork { ToolWork.parse(name: tool.name, arguments: tool.arguments, result: tool.result) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The terminal card already shows its command on the prompt line.
            ToolCardHeader(icon: icon, title: title, subtitle: { if case .terminal = work { return "" }; return work.headline }(), status: tool.status)
            content.padding(.top, 8)
        }
    }

    private var title: String {
        switch work {
        case .terminal(_, _, _, let background, _): background ? "Terminal · background" : "Terminal"
        case .process: "Process"
        case .diff: "Patch"
        case .fileRead: "Read file"
        case .fileWrite: "Wrote file"
        case .search: "Search files"
        case .code(let language, _, _, _): "Ran " + language.capitalized
        case .web(let kind, _, _, _): kind == "search" ? "Web search" : "Read web page"
        case .browser: "Browser"
        case .image: "Image"
        case .skill: "Skill"
        case .memory: "Memory"
        case .delegation: "Subagents"
        case .question: "Asked you"
        case .generic: tool.name
        }
    }
    private var icon: String {
        switch work {
        case .terminal, .process: "terminal"
        case .diff: "plusminus"
        case .fileRead: "doc.text"
        case .fileWrite: "square.and.pencil"
        case .search: "magnifyingglass"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .web: "globe"
        case .browser: "safari"
        case .image: "photo"
        case .skill: "book.closed"
        case .memory: "brain"
        case .delegation: "person.2"
        case .question: "questionmark.bubble"
        case .generic: "wrench.and.screwdriver"
        }
    }

    @ViewBuilder private var content: some View {
        switch work {
        case .terminal(let command, let output, let exitCode, _, let workdir):
            TerminalCard(command: command, output: output, exitCode: exitCode, workdir: workdir, running: tool.status == "running")
        case .process(_, _, let status, let output):
            VStack(alignment: .leading, spacing: 6) {
                if let status { Text(status.capitalized).font(.caption.weight(.medium)).foregroundStyle(Palette.muted) }
                if !output.isEmpty { MonoBlock(text: output, limit: 12) }
            }
        case .diff(_, let diff, let summary):
            VStack(alignment: .leading, spacing: 6) {
                DiffCard(diff: diff)
                if let summary, !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(Palette.orange) }
            }
        case .fileRead(let path, let content, let start, let total):
            CodeExcerpt(path: path, source: content, startLine: start, totalLines: total)
        case .fileWrite(let path, let bytes, let content):
            VStack(alignment: .leading, spacing: 6) {
                if let bytes { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " written").font(.caption).foregroundStyle(Palette.muted) }
                if let content, !content.isEmpty { CodeExcerpt(path: path, source: content, startLine: 1, totalLines: nil) }
            }
        case .search(_, _, let matches, let total):
            SearchCard(matches: matches, total: total)
        case .code(let language, let source, let output, let status):
            VStack(alignment: .leading, spacing: 8) {
                if !source.isEmpty { CodeCard(language: language, source: source) }
                if !output.isEmpty { TerminalCard(command: nil, output: output, exitCode: status == "error" ? 1 : nil, workdir: nil, running: false) }
            }
        case .web(_, _, let results, let excerpt):
            WebCard(results: results, excerpt: excerpt)
        case .browser(_, _, let output):
            if !output.isEmpty { MonoBlock(text: output, limit: 10) }
        case .image(_, let url):
            if let url, let link = URL(string: url), link.scheme?.hasPrefix("http") == true {
                AsyncImage(url: link) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 10))
            } else if !tool.result.isEmpty { ExpandableText(text: tool.result, limit: 6) }
        case .skill(_, _, let summary), .memory(_, let summary):
            if !summary.isEmpty { ExpandableText(text: summary, limit: 4) }
        case .delegation(let goals, let summary):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(goals.enumerated()), id: \.offset) { _, goal in
                    Label(goal, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(Palette.ink)
                }
                if !summary.isEmpty { ExpandableText(text: summary, limit: 6) }
            }
        case .question(let questions, let answers):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    Text(question).font(.callout)
                    if index < answers.count { Text("→ " + answers[index]).font(.callout.weight(.medium)).foregroundStyle(Palette.forest) }
                }
            }
        case .generic(let arguments, let result):
            VStack(alignment: .leading, spacing: 6) {
                if !arguments.isEmpty, arguments != "{}" { SectionLabel("Arguments"); MonoBlock(text: arguments, limit: 8) }
                if !result.isEmpty { SectionLabel("Result"); MonoBlock(text: result, limit: 12) }
            }
        }
    }
}

// MARK: Building blocks

private struct ToolCardHeader: View {
    let icon: String, title: String, subtitle: String, status: String
    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch status {
                case "running": ProgressView().controlSize(.mini)
                case "failed": Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.orange)
                case "interrupted": Image(systemName: "minus.circle").foregroundStyle(Palette.muted)
                default: Image(systemName: icon).foregroundStyle(Palette.forest)
                }
            }.font(.system(size: 12, weight: .semibold)).frame(width: 16)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + (subtitle.isEmpty ? "" : ", " + subtitle) + (status == "failed" ? ", failed" : status == "running" ? ", running" : ""))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(Palette.sectionLabel) }
}

/// Monospaced text on the code surface, clipped to `limit` lines until expanded.
struct MonoBlock: View {
    let text: String
    var limit = 12
    var color: Color = Palette.ink
    @State private var expanded = TranscriptDebug.expandAll
    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
    var body: some View {
        let clipped = !expanded && lines.count > limit
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(clipped ? lines.suffix(limit).joined(separator: "\n") : text)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(color)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
            }
            if lines.count > limit {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                    .font(.caption2.weight(.medium)).foregroundStyle(Palette.forest)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.code, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}

private struct ExpandableText: View {
    let text: String
    var limit = 4
    @State private var expanded = TranscriptDebug.expandAll
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.callout).foregroundStyle(Palette.muted).lineLimit(expanded ? nil : limit).textSelection(.enabled)
            if text.count > 240 { Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.font(.caption2.weight(.medium)).foregroundStyle(Palette.forest) }
        }
    }
}

/// A shell transcript: prompt line, output (tail first when long), exit code.
struct TerminalCard: View {
    let command: String?
    let output: String
    let exitCode: Int?
    let workdir: String?
    let running: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command, !command.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("$").foregroundStyle(Palette.forest)
                    Text(command).foregroundStyle(Palette.ink).textSelection(.enabled)
                }.font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            if !output.isEmpty {
                let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                TerminalOutput(lines: lines)
            } else if running {
                Text("Running…").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 8) {
                if let workdir { Text(ToolWork.shortPath(workdir)).lineLimit(1) }
                Spacer()
                if let exitCode {
                    Text(exitCode == 0 ? "exit 0" : "exit \(exitCode)").foregroundStyle(exitCode == 0 ? Palette.sectionLabel : Palette.orange)
                }
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.sectionLabel)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}

private struct TerminalOutput: View {
    let lines: [Substring]
    @State private var expanded = TranscriptDebug.expandAll
    private let limit = 14
    var body: some View {
        let clipped = !expanded && lines.count > limit
        VStack(alignment: .leading, spacing: 4) {
            if clipped {
                Button("\(lines.count - limit) earlier lines") { expanded = true }
                    .font(.caption2.weight(.medium)).foregroundStyle(Palette.forest)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text((clipped ? Array(lines.suffix(limit)) : lines).joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
            }
            if expanded && lines.count > limit {
                Button("Show less") { expanded = false }.font(.caption2.weight(.medium)).foregroundStyle(Palette.forest)
            }
        }
    }
}

/// Unified diff with added/removed lines tinted and hunk headers set apart.
struct DiffCard: View {
    let diff: String
    @State private var expanded = TranscriptDebug.expandAll
    private let limit = 40
    private var rows: [Substring] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") }
    }
    private var counts: (Int, Int) {
        rows.reduce((0, 0)) { total, line in
            line.hasPrefix("+") ? (total.0 + 1, total.1) : line.hasPrefix("-") ? (total.0, total.1 + 1) : total
        }
    }
    var body: some View {
        let shown = expanded ? rows : Array(rows.prefix(limit))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("+\(counts.0)").foregroundStyle(Palette.codeString)
                Text("−\(counts.1)").foregroundStyle(Palette.codeDeleted)
                Spacer()
                Button { UIPasteboard.general.string = diff } label: { Image(systemName: "doc.on.doc") }
                    .foregroundStyle(Palette.muted).accessibilityLabel("Copy diff")
            }.font(.system(size: 11, weight: .semibold, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 8)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        let added = line.hasPrefix("+"), removed = line.hasPrefix("-"), hunk = line.hasPrefix("@@")
                        Text(line.isEmpty ? " " : String(line))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(hunk ? Palette.codeFunction : added ? Palette.codeString : removed ? Palette.codeDeleted : Palette.muted)
                            .padding(.horizontal, 10).padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(added ? Palette.codeString.opacity(0.08) : removed ? Palette.codeDeleted.opacity(0.08) : .clear)
                    }
                }.fixedSize(horizontal: true, vertical: false).padding(.vertical, 6)
            }
            if rows.count > limit {
                Button(expanded ? "Show less" : "Show all \(rows.count) lines") { expanded.toggle() }
                    .font(.caption2.weight(.medium)).foregroundStyle(Palette.forest).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(Palette.code, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}

/// A file excerpt with line numbers from where the read started.
private struct CodeExcerpt: View {
    let path: String
    let source: String
    let startLine: Int?
    let totalLines: Int?
    @State private var expanded = TranscriptDebug.expandAll
    private let limit = 16
    var body: some View {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = expanded ? lines : Array(lines.prefix(limit))
        let first = startLine ?? 1
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(first + index)").foregroundStyle(Palette.sectionLabel).frame(minWidth: 28, alignment: .trailing)
                            Text(line.isEmpty ? " " : String(line)).foregroundStyle(Palette.ink)
                        }.font(.system(size: 12, design: .monospaced))
                    }
                }.fixedSize(horizontal: true, vertical: false).padding(10).textSelection(.enabled)
            }
            HStack {
                Text(lineSummary(lines.count, first: first)).foregroundStyle(Palette.sectionLabel)
                Spacer()
                if lines.count > limit {
                    Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }.foregroundStyle(Palette.forest)
                }
            }.font(.caption2.weight(.medium)).padding(.horizontal, 10).padding(.bottom, 8)
        }
        .background(Palette.code, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
    private func lineSummary(_ count: Int, first: Int) -> String {
        let range = count > 0 ? "Lines \(first)–\(first + count - 1)" : "Empty"
        return totalLines.map { range + " of \($0)" } ?? range
    }
}

private struct SearchCard: View {
    let matches: [ToolWork.SearchMatch]
    let total: Int?
    @State private var expanded = TranscriptDebug.expandAll
    private let limit = 8
    var body: some View {
        let shown = expanded ? matches : Array(matches.prefix(limit))
        VStack(alignment: .leading, spacing: 6) {
            if matches.isEmpty { Text("No matches").font(.caption).foregroundStyle(Palette.muted) }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, match in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(ToolWork.shortPath(match.path)).foregroundStyle(Palette.forest)
                        if let line = match.line { Text(":\(line)").foregroundStyle(Palette.sectionLabel) }
                    }.font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                    if !match.text.isEmpty {
                        Text(match.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                }
            }
            if matches.count > limit {
                Button(expanded ? "Show less" : "Show all \(matches.count)" + (total.map { $0 > matches.count ? " of \($0)" : "" } ?? "")) { expanded.toggle() }
                    .font(.caption2.weight(.medium)).foregroundStyle(Palette.forest)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.code, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}

private struct WebCard: View {
    let results: [ToolWork.WebResult]
    let excerpt: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { _, result in
                VStack(alignment: .leading, spacing: 2) {
                    if let url = URL(string: result.url), !result.url.isEmpty {
                        Link(result.title.isEmpty ? result.url : result.title, destination: url).font(.callout.weight(.medium)).lineLimit(2)
                        Text(url.host ?? result.url).font(.caption2).foregroundStyle(Palette.sectionLabel).lineLimit(1)
                    } else { Text(result.title).font(.callout.weight(.medium)) }
                    if !result.snippet.isEmpty { Text(result.snippet).font(.caption).foregroundStyle(Palette.muted).lineLimit(3) }
                }
            }
            if results.isEmpty && !excerpt.isEmpty { Text(excerpt).font(.caption).foregroundStyle(Palette.muted).lineLimit(6) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}
