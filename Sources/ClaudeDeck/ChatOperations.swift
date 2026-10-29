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

    // MARK: - Merge

    private static let droppedTypes: Set<String> = ["custom-title", "agent-name", "ai-title", "last-prompt"]
    private static let chainTypes: Set<String> = ["user", "assistant", "system", "attachment"]

    /// Concatenates `sessions` (oldest first) into a brand-new session in the first one's project.
    /// The first root message of each following chat is re-parented onto the last message of
    /// the previous one, so `claude --resume` sees one continuous conversation.
    /// Originals are left untouched.
    static func merge(_ sessions: [ChatSession], title: String) throws -> URL {
        guard let first = sessions.first else { throw ChatOperationError.io("Nessuna chat selezionata") }
        let newID = UUID().uuidString.lowercased()
        let projectFolder = first.fileURL.deletingLastPathComponent()
        let output = projectFolder.appendingPathComponent("\(newID).jsonl")

        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else {
            throw ChatOperationError.io("Impossibile creare \(output.path)")
        }
        defer { try? handle.close() }

        var lastUUID: String?
        do {
            for session in sessions {
                let data = try Data(contentsOf: session.fileURL, options: .alwaysMapped)
                var linkedRoot = false
                var sessionLastUUID: String?
                var writeError: Error?

                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    ChatIndexer.forEachLine(base: base, count: raw.count) { line, length in
                        guard writeError == nil else { return }
                        let lineData = Data(bytes: line, count: length)
                        guard var json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { return }
                        let type = json["type"] as? String ?? ""
                        if droppedTypes.contains(type) { return }

                        if json["sessionId"] != nil { json["sessionId"] = newID }

                        let isMain = chainTypes.contains(type) && json["isSidechain"] as? Bool != true
                        if isMain, let uuid = json["uuid"] as? String {
                            if !linkedRoot, json["parentUuid"] is NSNull, let previous = lastUUID {
                                json["parentUuid"] = previous
                                linkedRoot = true
                            }
                            sessionLastUUID = uuid
                        }

                        do {
                            var out = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
                            out.append(0x0A)
                            try handle.write(contentsOf: out)
                        } catch {
                            writeError = error
                        }
                    }
                }
                if let writeError { throw writeError }
                lastUUID = sessionLastUUID ?? lastUUID
            }
            try handle.close()
            try rename(
                ChatSession(id: newID, fileURL: output, projectDir: first.projectDir, modifiedAt: Date(), sizeBytes: 0),
                to: title
            )
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw ChatOperationError.io("Unione non riuscita: \(error.localizedDescription)")
        }
        return output
    }

    // MARK: - Helpers

    private static func append(_ records: [[String: Any]], to url: URL) throws {
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
