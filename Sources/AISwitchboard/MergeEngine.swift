import Foundation

/// Merges several Claude Code transcripts into one new, linear conversation.
///
/// For every source the *effective* conversation is taken: the parent chain from its last
/// message back to its root, i.e. exactly what `claude --resume` would load. This leaves out
/// rewound branches and the part already summarised by a compaction. Chains are then joined
/// in order: messages already written (forked chats share uuids) are skipped, the first new
/// message of each chat is re-parented onto the last one written, and a compaction boundary
/// at the start of a later chat is removed so its summary becomes a normal message instead of
/// cutting off everything before it.
///
/// The result is written to a temporary file and verified (unique uuids, one single chain)
/// before it is moved into place. Sources are never modified here.
enum MergeEngine {
    struct Result {
        let sessionID: String
        let fileURL: URL
        let messageCount: Int
        let skippedDuplicates: Int
        let compactedSources: Int
    }

    private struct Line {
        var json: [String: Any]
        var uuid: String? { json["uuid"] as? String }
        var parent: String? { json["parentUuid"] as? String }
        var type: String { json["type"] as? String ?? "" }
        var isSidechain: Bool { json["isSidechain"] as? Bool == true }
        var isMain: Bool { uuid != nil && !isSidechain }
    }

    private static let droppedTypes: Set<String> = ["custom-title", "agent-name", "ai-title", "last-prompt"]
    static let leafTypes: Set<String> = ["user", "assistant", "system", "attachment"]

    static func merge(
        _ sessions: [ChatSession],
        title: String,
        targetFolder: URL,
        configDirs: [URL]
    ) throws -> Result {
        guard sessions.count >= 2 else { throw ChatOperationError.io("Servono almeno due chat") }

        let newID = UUID().uuidString.lowercased()
        let finalURL = targetFolder.appendingPathComponent("\(newID).jsonl")
        let tempURL = targetFolder.appendingPathComponent(".\(newID).jsonl.partial")
        let newSideDir = targetFolder.appendingPathComponent(newID)

        var output: [[String: Any]] = []
        var written: Set<String> = []
        var lastMain: String?
        var skipped = 0
        var compacted = 0

        // Side folders of every source map to the new one (forked chats quote each other's paths).
        let sideDirAliases = sessions.flatMap(sideDirPaths(of:)).sorted { $0.count > $1.count }
        let sourceIDs = sessions.map(\.id)

        for session in sessions {
            var lines = try load(session, newID: newID, newSideDir: newSideDir, sideDirAliases: sideDirAliases, sourceIDs: sourceIDs)
            let chain = effectiveChain(lines)
            guard !chain.isEmpty else { continue }

            var keep = Set(chain.map { lines[$0].uuid! })
            var firstIndex = chain.first!

            // A later chat that starts at a compaction boundary: drop the boundary and turn the
            // summary into a regular message, otherwise resume would stop at the boundary.
            if lastMain != nil, lines[firstIndex].json["subtype"] as? String == "compact_boundary" {
                compacted += 1
                keep.remove(lines[firstIndex].uuid!)
                guard chain.count > 1 else { continue }
                firstIndex = chain[1]
                lines[firstIndex].json["isCompactSummary"] = nil
                lines[firstIndex].json["isVisibleInTranscriptOnly"] = nil
            }

            let duplicates = keep.intersection(written)
            skipped += duplicates.count
            keep.subtract(duplicates)

            // First message of this chat that is actually written, in chain order.
            let firstNew = chain.first { keep.contains(lines[$0].uuid!) }
            if let firstNew {
                lines[firstNew].json["parentUuid"] = lastMain.map { $0 as Any } ?? NSNull()
            }

            // Main messages are written exactly as the lines of the chain (a transcript can
            // contain rewritten copies of a message with a different parent).
            let chainLines = Set(chain.filter { keep.contains(lines[$0].uuid!) })
            for (index, line) in lines.enumerated() {
                if droppedTypes.contains(line.type) { continue }
                if let uuid = line.uuid {
                    if line.isSidechain {
                        guard !written.contains(uuid) else { continue }
                    } else {
                        guard chainLines.contains(index) else { continue }
                    }
                    written.insert(uuid)
                }
                output.append(line.json)
            }

            if let lastKept = chain.last(where: { keep.contains(lines[$0].uuid!) }) {
                lastMain = lines[lastKept].uuid
            }
        }

        try write(output, to: tempURL)
        let messageCount: Int
        do {
            messageCount = try verify(tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        for session in sessions {
            copySideFiles(of: session, to: newSideDir, newID: newID)
            copyFileHistory(from: session.id, to: newID, configDirs: configDirs)
        }

        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        try ChatOperations.rename(
            ChatSession(id: newID, fileURL: finalURL, projectDir: targetFolder.lastPathComponent, modifiedAt: Date(), sizeBytes: 0),
            to: title
        )

        return Result(
            sessionID: newID,
            fileURL: finalURL,
            messageCount: messageCount,
            skippedDuplicates: skipped,
            compactedSources: compacted
        )
    }

    // MARK: - Reading

    /// Parses a transcript, rewriting its session id and side-folder paths for the new session.
    private static func load(
        _ session: ChatSession,
        newID: String,
        newSideDir: URL,
        sideDirAliases: [String],
        sourceIDs: [String]
    ) throws -> [Line] {
        let data = try Data(contentsOf: session.fileURL, options: .alwaysMapped)
        var lines: [Line] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ChatIndexer.forEachLine(base: base, count: raw.count) { pointer, length in
                var text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
                if sourceIDs.contains(where: { text.contains($0) }) {
                    for old in sideDirAliases where text.contains(old) {
                        text = text.replacingOccurrences(of: old, with: newSideDir.path)
                    }
                }
                guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
                var line = Line(json: json)
                if line.json["sessionId"] != nil { line.json["sessionId"] = newID }
                lines.append(line)
            }
        }
        return lines
    }

    /// Indexes of the main-chain lines from root to leaf, the leaf being the last main message.
    private static func effectiveChain(_ lines: [Line]) -> [Int] {
        var indexByUUID: [String: Int] = [:]
        for (index, line) in lines.enumerated() where line.isMain {
            indexByUUID[line.uuid!] = index
        }
        guard let leaf = lines.lastIndex(where: { $0.isMain && leafTypes.contains($0.type) }) else { return [] }

        var chain: [Int] = []
        var visited: Set<String> = []
        var current: Int? = leaf
        while let index = current, let uuid = lines[index].uuid, visited.insert(uuid).inserted {
            chain.append(index)
            current = lines[index].parent.flatMap { indexByUUID[$0] }
        }
        return chain.reversed()
    }

    // MARK: - Writing and verification

    static func write(_ records: [[String: Any]], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for record in records {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }
    }

    /// Checks the merged file is one linear conversation; returns its message count.
    static func verify(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        var parents: [String: String?] = [:]
        var order: [String] = []
        var leaf: String?

        for line in data.split(separator: 0x0A) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let uuid = json["uuid"] as? String else { continue }
            if json["isSidechain"] as? Bool == true { continue }
            guard parents[uuid] == nil else {
                throw ChatOperationError.io("Verifica fallita: messaggio duplicato \(uuid)")
            }
            parents[uuid] = json["parentUuid"] as? String
            order.append(uuid)
            if leafTypes.contains(json["type"] as? String ?? "") { leaf = uuid }
        }
        guard let leaf else { throw ChatOperationError.io("Verifica fallita: nessun messaggio") }

        var count = 0
        var current: String? = leaf
        var seen: Set<String> = []
        while let uuid = current {
            guard seen.insert(uuid).inserted else { throw ChatOperationError.io("Verifica fallita: ciclo nella conversazione") }
            guard let parent = parents[uuid] else { throw ChatOperationError.io("Verifica fallita: messaggio mancante \(uuid)") }
            count += 1
            current = parent
        }
        guard count == order.count else {
            throw ChatOperationError.io("Verifica fallita: \(order.count - count) messaggi fuori dalla conversazione")
        }
        return count
    }

    // MARK: - Side files

    /// Tool results and subagent transcripts live in `<project>/<sessionId>/`.
    static func copySideFiles(of session: ChatSession, to newSideDir: URL, newID: String) {
        let source = session.fileURL.deletingPathExtension()
        let oldSideDirs = sideDirPaths(of: session)
        copyTree(from: source, to: newSideDir) { file, data in
            guard ["jsonl", "json"].contains(file.pathExtension), var text = String(data: data, encoding: .utf8) else { return data }
            for old in oldSideDirs {
                text = text.replacingOccurrences(of: old, with: newSideDir.path)
            }
            return Data(text.replacingOccurrences(of: session.id, with: newID).utf8)
        }
    }

    /// Every spelling of a chat's side folder: the real path and the one seen through each
    /// account's `projects` symlink (`~/.claude-<name>/projects/...`), which is what transcripts record.
    static func sideDirPaths(of session: ChatSession) -> [String] {
        let home = ClaudePaths.home
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        var paths = [session.fileURL.deletingPathExtension().path]
        for entry in entries where entry == ".claude" || entry.hasPrefix(".claude-") {
            paths.append(home.appendingPathComponent("\(entry)/projects/\(session.projectDir)/\(session.id)").path)
        }
        // Longest first so a path is never partially replaced by a shorter alias.
        return Array(Set(paths)).sorted { $0.count > $1.count }
    }

    /// File backups used by rewind live in `<configDir>/file-history/<sessionId>/`.
    static func copyFileHistory(from oldID: String, to newID: String, configDirs: [URL]) {
        for dir in configDirs {
            let history = dir.appendingPathComponent("file-history")
            copyTree(from: history.appendingPathComponent(oldID), to: history.appendingPathComponent(newID)) { _, data in data }
        }
    }

    /// Recursive copy that never overwrites existing files.
    private static func copyTree(from source: URL, to destination: URL, transform: (URL, Data) -> Data) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let file as URL in enumerator {
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let target = destination.appendingPathComponent(relative)
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard !fm.fileExists(atPath: target.path), let data = try? Data(contentsOf: file) else { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? transform(file, data).write(to: target)
        }
    }
}
