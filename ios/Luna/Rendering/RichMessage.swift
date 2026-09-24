import SwiftUI
import Textual

struct RichBlock: Identifiable, Equatable {
    enum Kind: Equatable { case markdown, code(String) }
    let id: Int
    let kind: Kind
    let content: String
}

enum MarkdownBlocks {
    private static let opening = try! NSRegularExpression(pattern: "(?m)^ {0,3}(`{3,}|~{3,})([^\\r\\n]*)(?:\\r\\n|\\n|\\r|$)")

    static func parse(_ text: String) -> [RichBlock] {
        let source = text as NSString
        var offset = 0
        var blocks: [RichBlock] = []
        func append(_ kind: RichBlock.Kind, _ content: String) {
            if !content.isEmpty || kind != .markdown {
                blocks.append(RichBlock(id: blocks.count, kind: kind, content: content))
            }
        }
        while offset < source.length {
            guard let match = opening.firstMatch(in: text, range: NSRange(location: offset, length: source.length-offset)) else {
                append(.markdown, source.substring(from: offset)); break
            }
            if match.range.location > offset {
                append(.markdown, source.substring(with: NSRange(location: offset, length: match.range.location-offset)))
            }
            let fence = source.substring(with: match.range(at: 1))
            let language = source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let start = NSMaxRange(match.range)
            // Backtick fences cannot have backticks in their info string.
            if fence.first == "`", language.contains("`") {
                append(.markdown, source.substring(with: match.range)); offset = start; continue
            }
            let character = NSRegularExpression.escapedPattern(for: String(fence.first!))
            let closing = try! NSRegularExpression(pattern: "(?m)^ {0,3}\(character){\(fence.count),}[ \\t]*(?:\\r\\n|\\n|\\r|$)")
            if let end = closing.firstMatch(in: text, range: NSRange(location: start, length: source.length-start)) {
                append(.code(language), source.substring(with: NSRange(location: start, length: end.range.location-start)))
                offset = NSMaxRange(end.range)
            } else {
                // Keep the card visible while its contents and closing fence stream in.
                append(.code(language), source.substring(from: start)); break
            }
        }
        return blocks
    }
}

struct CodeLanguage: Equatable {
    let identifier: String
    let label: String

    init(info: String, source: String) {
        var hint = String(info.split(whereSeparator: \.isWhitespace).first ?? "").lowercased()
        hint = hint.trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
        if hint.hasPrefix("language-") { hint.removeFirst("language-".count) }
        if hint.contains("."), let fileExtension = hint.split(separator: ".").last { hint = String(fileExtension) }
        let aliases = ["js": "javascript", "ts": "typescript", "py": "python", "python3": "python",
                       "sh": "bash", "shell": "bash", "zsh": "bash", "yml": "yaml", "c++": "cpp", "h++": "cpp",
                       "c#": "csharp", "cs": "csharp", "objc": "objectivec", "objective-c": "objectivec",
                       "html": "markup", "xml": "markup", "md": "markdown", "patch": "diff", "dockerfile": "docker",
                       "text": "plain", "txt": "plain", "plaintext": "plain"]
        hint = aliases[hint] ?? hint
        if hint.isEmpty {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only infer unambiguous data/diffs inside an already-fenced block.
            if (trimmed.first == "{" || trimmed.first == "["),
               (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil { hint = "json" }
            else if trimmed.hasPrefix("diff --git ") || (trimmed.hasPrefix("--- ") && trimmed.contains("\n+++ ")) { hint = "diff" }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        identifier = hint.unicodeScalars.allSatisfy(allowed.contains) ? hint : "plain"
        let labels = ["swift": "Swift", "javascript": "JavaScript", "typescript": "TypeScript", "jsx": "JSX", "tsx": "TSX",
                      "python": "Python", "json": "JSON", "bash": "Shell", "yaml": "YAML", "cpp": "C++", "c": "C",
                      "csharp": "C#", "objectivec": "Objective-C", "markup": "HTML / XML", "css": "CSS", "sql": "SQL",
                      "diff": "Diff", "markdown": "Markdown", "docker": "Dockerfile", "plain": "Plain text", "": "Code"]
        label = labels[identifier] ?? identifier
    }
}

enum CodePresentation {
    /// A source file can itself contain Markdown fences. The display wrapper
    /// must be longer than every backtick run so the code is never reinterpreted.
    static func markdown(source: String, language: String) -> String {
        var longest = 0, current = 0
        for byte in source.utf8 {
            current = byte == 96 ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + source + (source.hasSuffix("\n") ? "" : "\n") + fence
    }
    static func lineCount(_ source: String) -> Int {
        guard !source.isEmpty else { return 0 }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).count - (normalized.hasSuffix("\n") ? 1 : 0)
    }
}

struct RichMessage: View, Equatable {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(MarkdownBlocks.parse(text)) { block in
                switch block.kind {
                case .markdown:
                    ForEach(MediaBlocks.parse(block.content)) { part in
                        if let attachment = part.attachment {
                            ReceivedAttachmentView(attachment: attachment).id(attachment.id)
                        } else {
                            StructuredText(markdown: part.text)
                                .textual.textSelection(.enabled)
                                .textual.inlineStyle(.luna)
                                .textual.highlighterTheme(.luna)
                                .textual.structuredTextStyle(.gitHub)
                                .foregroundStyle(Palette.ink)
                                .font(.system(size: 16))
                                .tint(Palette.forest)
                        }
                    }
                case .code(let language): CodeCard(language: language, source: block.content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeCard: View {
    let language: String
    let source: String
    @State private var copied = false
    @State private var expanded = false
    @State private var wrapsLines = false
    private var displayed: String { expanded ? source : String(source.prefix(16000)) }
    private var syntax: CodeLanguage { CodeLanguage(info: language, source: displayed) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(syntax.label).font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Palette.forest)
                Spacer(minLength: 4)
                Button { wrapsLines.toggle() } label: {
                    Image(systemName: wrapsLines ? "arrow.left.and.right" : "arrow.turn.down.left")
                }
                .accessibilityLabel(wrapsLines ? "Scroll code horizontally" : "Wrap code lines")
                Button {
                    UIPasteboard.general.string = source
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .accessibilityLabel("Copy \(syntax.label) code")
            }
            .font(.caption).buttonStyle(.borderless)
            .foregroundStyle(Palette.muted).padding(.horizontal, 14).padding(.vertical, 12)
            Rectangle().fill(Palette.line).frame(height: 1)
            StructuredText(markdown: CodePresentation.markdown(source: displayed, language: syntax.identifier))
                .textual.textSelection(.enabled)
                .textual.codeBlockStyle(LunaCodeBlockStyle(wrapsLines: wrapsLines))
                .textual.highlighterTheme(.luna)
                .textual.structuredTextStyle(.gitHub)
                .font(.system(size: 13, design: .monospaced))
            HStack {
                let count = CodePresentation.lineCount(source)
                Text("\(count) \(count == 1 ? "line" : "lines")")
                Spacer()
                if source.count > 16000 && !expanded {
                    Button("Show full code") { expanded = true }
                }
            }
            .font(.caption2).foregroundStyle(Palette.muted)
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .background(Palette.code).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
    }
}

private extension InlineStyle {
    static var luna: InlineStyle {
        InlineStyle()
            .code(.monospaced, .fontScale(0.85), .foregroundColor(Palette.forest), .backgroundColor(Palette.card))
            .strong(.fontWeight(.semibold))
            .link(.foregroundColor(Palette.forest))
    }
}

private struct LunaCodeBlockStyle: StructuredText.CodeBlockStyle {
    var wrapsLines = false
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if wrapsLines { content(configuration) }
            else { Overflow { content(configuration) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.code)
    }
    @MainActor private func content(_ configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.225))
            .fixedSize(horizontal: false, vertical: true)
            .monospaced()
            .padding(14)
    }
}

private extension StructuredText.HighlighterTheme {
    static let luna = Self(
        foregroundColor: DynamicColor(Palette.ink),
        backgroundColor: DynamicColor(Palette.code),
        tokenProperties: [
            .keyword: AnyTextProperty(.foregroundColor(Palette.codeKeyword)),
            .builtin: AnyTextProperty(.foregroundColor(Palette.codeType)),
            .literal: AnyTextProperty(.foregroundColor(Palette.codeNumber)),
            .boolean: AnyTextProperty(.foregroundColor(Palette.codeNumber)),
            .number: AnyTextProperty(.foregroundColor(Palette.codeNumber)),
            .string: AnyTextProperty(.foregroundColor(Palette.codeString)),
            .char: AnyTextProperty(.foregroundColor(Palette.codeString)),
            .regex: AnyTextProperty(.foregroundColor(Palette.codeString)),
            .className: AnyTextProperty(.foregroundColor(Palette.codeType)),
            .function: AnyTextProperty(.foregroundColor(Palette.codeFunction)),
            .functionName: AnyTextProperty(.foregroundColor(Palette.codeFunction)),
            .property: AnyTextProperty(.foregroundColor(Palette.codeFunction)),
            .variable: AnyTextProperty(.foregroundColor(Palette.ink)),
            .constant: AnyTextProperty(.foregroundColor(Palette.codeNumber)),
            .comment: AnyTextProperty(.foregroundColor(Palette.muted)),
            .blockComment: AnyTextProperty(.foregroundColor(Palette.muted)),
            .docComment: AnyTextProperty(.foregroundColor(Palette.muted)),
            .operator: AnyTextProperty(.foregroundColor(Palette.codeKeyword)),
            .punctuation: AnyTextProperty(.foregroundColor(Palette.muted)),
            .tag: AnyTextProperty(.foregroundColor(Palette.codeKeyword)),
            .attributeName: AnyTextProperty(.foregroundColor(Palette.codeFunction)),
            .attributeValue: AnyTextProperty(.foregroundColor(Palette.codeString)),
            .directive: AnyTextProperty(.foregroundColor(Palette.codeKeyword)),
            .preprocessor: AnyTextProperty(.foregroundColor(Palette.codeKeyword)),
            .attribute: AnyTextProperty(.foregroundColor(Palette.codeType)),
            .inserted: AnyTextProperty(.foregroundColor(Palette.codeString)),
            .deleted: AnyTextProperty(.foregroundColor(Palette.codeDeleted)),
            "coord": AnyTextProperty(.foregroundColor(Palette.codeFunction)),
            "deleted-sign": AnyTextProperty(.foregroundColor(Palette.codeDeleted)),
            "inserted-sign": AnyTextProperty(.foregroundColor(Palette.codeString)),
        ]
    )
}
