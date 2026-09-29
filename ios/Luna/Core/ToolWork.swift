import Foundation

/// A typed reading of one tool call, so the chat can show terminal output as a
/// terminal, a patch as a diff, a file read as code, and so on. Parsing is
/// lenient: Hermes' result shapes vary by version and truncation, so every
/// case falls back to `.generic` rather than failing.
enum ToolWork: Equatable {
    case terminal(command: String, output: String, exitCode: Int?, background: Bool, workdir: String?)
    case process(action: String, sessionID: String?, status: String?, output: String)
    case diff(path: String?, diff: String, summary: String?)
    case fileRead(path: String, content: String, startLine: Int?, totalLines: Int?)
    case fileWrite(path: String, bytes: Int?, content: String?)
    case search(pattern: String, path: String?, matches: [SearchMatch], total: Int?)
    case code(language: String, source: String, output: String, status: String?)
    case web(kind: String, query: String, results: [WebResult], excerpt: String)
    case browser(action: String, detail: String, output: String)
    case image(prompt: String, url: String?)
    case skill(name: String, action: String, summary: String)
    case memory(action: String, content: String)
    case delegation(goals: [String], summary: String)
    case question(questions: [String], answers: [String])
    case generic(arguments: String, result: String)

    struct SearchMatch: Equatable { let path: String; let line: Int?; let text: String }
    struct WebResult: Equatable { let title: String; let url: String; let snippet: String }

    /// Parse by tool family. `result` is the raw text Hermes returned (usually JSON).
    static func parse(name: String, arguments: String, result: String) -> ToolWork {
        let args = object(arguments) ?? [:]
        let value = object(result)
        func s(_ key: String, _ from: JSONObject? = nil) -> String? { (from ?? args)[key].flatMap(Self.text) }
        func n(_ key: String, _ from: JSONObject?) -> Int? { from?[key]?.number.map { Int($0) } }
        let lower = name.lowercased()
        switch lower {
        case "terminal", "shell", "bash", "run_command":
            let output = s("output", value) ?? s("stdout", value) ?? (value == nil ? result : "")
            let stderr = s("stderr", value) ?? ""
            let joined = [output, stderr].filter { !$0.isEmpty }.joined(separator: output.isEmpty || stderr.isEmpty ? "" : "\n")
            let background = args["background"]?.bool == true || value?["session_id"]?.string != nil && output.isEmpty
            let message = s("error", value).map { "\n" + $0 } ?? ""
            return .terminal(command: s("command") ?? s("cmd") ?? "", output: joined + (joined.contains(message) ? "" : message),
                             exitCode: n("exit_code", value) ?? n("returncode", value), background: background, workdir: s("workdir"))
        case "process", "process_manage":
            return .process(action: s("action") ?? "poll", sessionID: s("session_id") ?? s("session_id", value),
                            status: s("status", value), output: s("output", value) ?? s("output_preview", value) ?? (value == nil ? result : ""))
        case "patch", "apply_patch", "edit_file", "str_replace":
            if let diff = s("diff", value), !diff.isEmpty {
                return .diff(path: s("path") ?? (value?["files_modified"]?.array?.first).flatMap(Self.text), diff: diff, summary: s("error", value))
            }
            if let old = s("old_string"), let new = s("new_string") {
                return .diff(path: s("path"), diff: syntheticDiff(old: old, new: new), summary: s("error", value))
            }
            if let body = s("patch") ?? s("input") { return .diff(path: s("path"), diff: body, summary: s("error", value)) }
        case "read_file", "view_file", "cat":
            let raw = s("content", value) ?? (value == nil ? result : "")
            let (content, start) = stripLineNumbers(raw)
            return .fileRead(path: s("path") ?? "", content: content, startLine: start ?? n("offset", args), totalLines: n("total_lines", value))
        case "write_file", "create_file":
            return .fileWrite(path: s("path") ?? s("resolved_path", value) ?? "", bytes: n("bytes_written", value), content: s("content"))
        case "search_files", "grep", "find_files", "glob":
            return .search(pattern: s("pattern") ?? s("query") ?? "", path: s("path"), matches: searchMatches(value, raw: result),
                           total: n("total_count", value))
        case "execute_code", "python", "run_code", "code_interpreter":
            let output = s("output", value) ?? s("stdout", value) ?? (value == nil ? result : "")
            let error = s("error", value) ?? s("stderr", value) ?? ""
            return .code(language: s("language") ?? "python", source: s("code") ?? s("source") ?? "",
                         output: [output, error].filter { !$0.isEmpty }.joined(separator: "\n"), status: s("status", value))
        case "web_search", "search_web":
            return .web(kind: "search", query: s("query") ?? "", results: webResults(value), excerpt: "")
        case "web_extract", "fetch_url", "web_fetch":
            let urls = args["urls"]?.array?.compactMap(Self.text) ?? [s("url") ?? ""]
            let pages = (value?["results"]?.array ?? []).compactMap(\.object)
            let results = pages.map { WebResult(title: $0["title"].flatMap(Self.text) ?? "", url: $0["url"].flatMap(Self.text) ?? "",
                                                snippet: String(($0["content"].flatMap(Self.text) ?? $0["error"].flatMap(Self.text) ?? "").prefix(600))) }
            return .web(kind: "extract", query: urls.joined(separator: ", "), results: results, excerpt: results.isEmpty ? String(result.prefix(600)) : "")
        case "vision_analyze", "image_generate", "generate_image":
            return .image(prompt: s("question") ?? s("prompt") ?? "", url: s("image_url") ?? s("url", value) ?? s("image", value))
        case "skill_view", "skill_manage", "skills_list":
            return .skill(name: s("name") ?? "", action: lower == "skills_list" ? "list" : lower == "skill_view" ? "view" : s("action") ?? "manage",
                          summary: s("description", value) ?? s("message", value) ?? "")
        case "memory":
            return .memory(action: s("action") ?? "update", content: s("content") ?? s("message", value) ?? "")
        case "delegate_task":
            let goals = (args["tasks"]?.array ?? []).compactMap { $0.object?["goal"].flatMap(Self.text) } + [s("goal")].compactMap { $0 }
            return .delegation(goals: goals, summary: s("summary", value) ?? (value == nil ? result : s("results", value) ?? ""))
        case "clarify":
            let questions = (args["questions"]?.array ?? []).compactMap { $0.object?["question"].flatMap(Self.text) }
            let answers = (value?["responses"]?.array ?? []).compactMap { $0.object?["answer"].flatMap(Self.text) ?? Self.text($0) }
            return .question(questions: questions, answers: answers)
        default:
            if lower.hasPrefix("browser") || lower.hasPrefix("computer") || lower.contains("screenshot") {
                return .browser(action: s("action") ?? name, detail: s("url") ?? s("code").map { String($0.prefix(200)) } ?? "",
                                output: s("output", value) ?? s("result", value) ?? (value == nil ? result : ""))
            }
        }
        return .generic(arguments: pretty(arguments), result: pretty(result))
    }

    /// A short, human line for the collapsed header of any tool row.
    var headline: String {
        switch self {
        case .terminal(let command, _, _, _, _): command.split(separator: "\n").first.map(String.init) ?? "Terminal"
        case .process(let action, let id, _, _): action + (id.map { " · " + $0 } ?? "")
        case .diff(let path, _, _): path.map(Self.shortPath) ?? "Patch"
        case .fileRead(let path, _, _, _): Self.shortPath(path)
        case .fileWrite(let path, _, _): Self.shortPath(path)
        case .search(let pattern, let path, _, let total): "“\(pattern)”" + (path.map { " in " + Self.shortPath($0) } ?? "") + (total.map { " · \($0)" } ?? "")
        case .code(let language, let source, _, _): source.split(separator: "\n").first.map(String.init) ?? language
        case .web(_, let query, _, _): query
        case .browser(let action, let detail, _): detail.isEmpty ? action : action + " · " + detail
        case .image(let prompt, _): prompt
        case .skill(let name, let action, _): action + (name.isEmpty ? "" : " · " + name)
        case .memory(let action, _): action
        case .delegation(let goals, _): goals.first ?? "Subagents"
        case .question(let questions, _): questions.first ?? "Question"
        case .generic: ""
        }
    }

    // MARK: Helpers

    static func object(_ text: String) -> JSONObject? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" else {
            // Some results are wrapped in an untrusted-content envelope; find the JSON inside.
            guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else { return nil }
            return try? JSONDecoder().decode(JSONObject.self, from: Data(trimmed[start...end].utf8))
        }
        return try? JSONDecoder().decode(JSONObject.self, from: Data(trimmed.utf8))
    }
    static func text(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): String(flag)
        case .null: nil
        default: (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
        }
    }
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(3).joined(separator: "/") : path
    }
    /// read_file returns `N|text` rows; show plain text and remember the first line number.
    static func stripLineNumbers(_ raw: String) -> (String, Int?) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var first: Int?, stripped: [Substring] = [], numbered = 0
        for line in lines {
            if let bar = line.firstIndex(of: "|"), let number = Int(line[..<bar].trimmingCharacters(in: .whitespaces)) {
                if first == nil { first = number }
                stripped.append(line[line.index(after: bar)...]); numbered += 1
            } else { stripped.append(line) }
        }
        return numbered * 2 >= max(lines.count, 1) ? (stripped.joined(separator: "\n"), first) : (raw, nil)
    }
    static func syntheticDiff(old: String, new: String) -> String {
        (old.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }
         + new.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }).joined(separator: "\n")
    }
    static func searchMatches(_ value: JSONObject?, raw: String) -> [SearchMatch] {
        if let rows = value?["matches"]?.array {
            return rows.compactMap(\.object).map {
                SearchMatch(path: $0["path"].flatMap(text) ?? $0["file"].flatMap(text) ?? "", line: $0["line"]?.number.map { Int($0) },
                            text: $0["content"].flatMap(text) ?? $0["text"].flatMap(text) ?? "")
            }
        }
        // Path-grouped text: a path line followed by indented `line: text` rows.
        guard let grouped = value?["matches_text"].flatMap(text) ?? (value == nil ? raw : nil) else { return [] }
        var matches: [SearchMatch] = [], path = ""
        for line in grouped.split(separator: "\n") {
            if !line.hasPrefix(" ") { path = String(line); continue }
            let body = line.trimmingCharacters(in: .whitespaces)
            if let colon = body.firstIndex(of: ":"), let number = Int(body[..<colon]) {
                matches.append(SearchMatch(path: path, line: number, text: String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            } else { matches.append(SearchMatch(path: path, line: nil, text: body)) }
        }
        if matches.isEmpty, !path.isEmpty { matches = grouped.split(separator: "\n").map { SearchMatch(path: String($0), line: nil, text: "") } }
        return matches
    }
    static func webResults(_ value: JSONObject?) -> [WebResult] {
        let rows = value?["data"]?.object?["web"]?.array ?? value?["results"]?.array ?? value?["web"]?.array ?? []
        return rows.compactMap(\.object).map {
            WebResult(title: $0["title"].flatMap(text) ?? "", url: $0["url"].flatMap(text) ?? "",
                      snippet: $0["description"].flatMap(text) ?? $0["snippet"].flatMap(text) ?? "")
        }
    }
    static func pretty(_ text: String) -> String {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value.object != nil || value.array != nil else { return text }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? text
    }
}
