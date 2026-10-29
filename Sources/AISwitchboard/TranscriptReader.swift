import Foundation

/// Turns a transcript file into a readable list of messages for the preview.
enum TranscriptReader {
    private static let userNeedle = Array(#""type":"user""#.utf8)
    private static let assistantNeedle = Array(#""type":"assistant""#.utf8)

    static func read(_ url: URL, limit: Int = 500) -> (messages: [TranscriptMessage], truncated: Bool) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return ([], false) }
        var messages: [TranscriptMessage] = []
        var pendingTools: [String] = []
        var counter = 0

        func flushTools(at date: Date?) {
            guard !pendingTools.isEmpty else { return }
            messages.append(TranscriptMessage(id: counter, kind: .tools(pendingTools), text: "", timestamp: date))
            counter += 1
            pendingTools = []
        }

        func append(_ kind: TranscriptMessage.Kind, _ text: String, _ date: Date?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            flushTools(at: date)
            messages.append(TranscriptMessage(id: counter, kind: kind, text: String(trimmed.prefix(6000)), timestamp: date))
            counter += 1
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ChatIndexer.forEachLine(base: base, count: raw.count) { line, length in
                guard ChatIndexer.contains(line, length, userNeedle) || ChatIndexer.contains(line, length, assistantNeedle) else { return }
                let lineData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none)
                guard let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                      let type = json["type"] as? String,
                      json["isSidechain"] as? Bool != true,
                      let message = json["message"] as? [String: Any] else { return }
                let date = (json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }

                if type == "user" {
                    guard json["isMeta"] as? Bool != true else { return }
                    if let content = message["content"] as? String {
                        handleUserText(content, date: date, append: append)
                    } else if let blocks = message["content"] as? [[String: Any]] {
                        for block in blocks where block["type"] as? String == "text" {
                            handleUserText(block["text"] as? String ?? "", date: date, append: append)
                        }
                    }
                } else if type == "assistant", let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text":
                            append(.assistant, block["text"] as? String ?? "", date)
                        case "tool_use":
                            pendingTools.append(toolSummary(block))
                        default:
                            break
                        }
                    }
                }
            }
        }
        flushTools(at: nil)

        let truncated = messages.count > limit
        return (truncated ? Array(messages.suffix(limit)) : messages, truncated)
    }

    private static func handleUserText(_ text: String, date: Date?, append: (TranscriptMessage.Kind, String, Date?) -> Void) {
        if text.hasPrefix("<command-name>") {
            let name = between(text, "<command-name>", "</command-name>") ?? ""
            let args = between(text, "<command-args>", "</command-args>") ?? ""
            append(.command, "\(name) \(args)", date)
            return
        }
        if text.hasPrefix("<local-command") || text.hasPrefix("<system-reminder>") || text.hasPrefix("<task-notification>") {
            return
        }
        append(.user, text, date)
    }

    private static func toolSummary(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let detail = (input["description"] as? String)
            ?? (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? (input["command"] as? String)
            ?? (input["pattern"] as? String)
            ?? (input["url"] as? String)
            ?? ""
        let short = detail.replacingOccurrences(of: "\n", with: " ").prefix(90)
        return short.isEmpty ? name : "\(name) · \(short)"
    }

    private static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return nil }
        return String(text[a.upperBound..<b.lowerBound])
    }
}
