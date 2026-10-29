import Foundation

enum ChatOperationError: LocalizedError {
    case active(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .active(let title): return "“\(title)” è in uso in una sessione aperta: chiudila prima."
        case .io(let message): return message
        }
    }
}

enum ChatOperations {
    // MARK: - Rename

    /// Same records `/rename` writes: Claude Code picks the last one.
    static func rename(_ session: ChatSession, to title: String) throws {
        let records: [[String: Any]] = [
            ["type": "custom-title", "customTitle": title, "sessionId": session.id],
            ["type": "agent-name", "agentName": title, "sessionId": session.id],
        ]
        try append(records, to: session.fileURL)
    }

    // MARK: - Delete

    /// Moves the transcript and its side folder (tool results, subagents) to the Trash.
    static func trash(_ session: ChatSession) throws {
        let fm = FileManager.default
        try fm.trashItem(at: session.fileURL, resultingItemURL: nil)
        let sideDir = session.fileURL.deletingPathExtension()
        if fm.fileExists(atPath: sideDir.path) {
            try fm.trashItem(at: sideDir, resultingItemURL: nil)
        }
    }

    // MARK: - Helpers

    static func append(_ records: [[String: Any]], to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var payload = Data()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { payload.append(0x0A) }
            try handle.seekToEnd()
        }
        for record in records {
            payload.append(try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]))
            payload.append(0x0A)
        }
        try handle.write(contentsOf: payload)
    }
}
