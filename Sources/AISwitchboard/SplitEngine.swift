import Foundation

/// Splits one Claude Code transcript into several new chats, one per topic.
///
/// The whole history is used, compactions included: the parent chain is walked back from the
/// last message and a compaction boundary is crossed through its `logicalParentUuid`, while the
/// boundary and its summary are left out. The history is cut into turns (a prompt plus everything
/// Claude did until the next prompt) and every topic gets the turns assigned to it, re-chained
/// in their original order. A turn is never cut in half, so tool calls keep their results.
///
/// A topic can start with a summary of the original chat, written in the same format Claude Code
/// uses after a compaction. Every new chat is written to a temporary file and verified; nothing
/// is moved into place until all of them pass. The source is never modified here.
enum SplitEngine {
    struct Turn: Identifiable, Sendable {
        let id: Int
        let prompt: String
        let timestamp: Date?
        let messageCount: Int
        /// Prompt plus Claude's text replies, shortened, for summaries.
        let digest: String
    }

    struct Topic: Sendable {
        var title: String
        var folder: String
        var turns: [Int]
        var summary: String?
    }

    struct Result: Sendable {
        let sessionID: String
        let fileURL: URL
        let projectDir: String
        let title: String
        let folder: String
        let messageCount: Int
    }

    /// A parsed transcript ready to be split.
    final class Source: @unchecked Sendable {
        let chat: ChatSession
        let turns: [Turn]
        fileprivate let lines: [Line]
        /// Chain line indexes of each turn.
        fileprivate let turnLines: [[Int]]

        fileprivate init(chat: ChatSession, turns: [Turn], lines: [Line], turnLines: [[Int]]) {
            self.chat = chat
            self.turns = turns
            self.lines = lines
            self.turnLines = turnLines
        }
    }

    fileprivate struct Line {
        let raw: String
        let json: [String: Any]
        var uuid: String? { json["uuid"] as? String }
        var type: String { json["type"] as? String ?? "" }
        var isSidechain: Bool { json["isSidechain"] as? Bool == true }
        var isMain: Bool { uuid != nil && !isSidechain }
    }

    // MARK: - Reading

    static func analyze(_ chat: ChatSession) throws -> Source {
        let data = try Data(contentsOf: chat.fileURL, options: .alwaysMapped)
        var lines: [Line] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ChatIndexer.forEachLine(base: base, count: raw.count) { pointer, length in
                let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
                guard let json = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] else { return }
                lines.append(Line(raw: String(decoding: bytes, as: UTF8.self), json: json))
            }
        }

        let chain = fullChain(lines)
        var turnLines: [[Int]] = []
        for index in chain {
            if isPrompt(lines[index]) || turnLines.isEmpty {
                turnLines.append([index])
            } else {
                turnLines[turnLines.count - 1].append(index)
            }
        }
        // Lines before the first prompt (hooks, attachments) belong to the first turn.
        if turnLines.count > 1, !isPrompt(lines[turnLines[0][0]]) {
            turnLines[1] = turnLines[0] + turnLines[1]
            turnLines.removeFirst()
        }
        guard !turnLines.isEmpty else { throw ChatOperationError.io("La chat non contiene messaggi") }

        let turns = turnLines.enumerated().map { id, indexes in
            makeTurn(id: id, lines: indexes.map { lines[$0] })
        }
        return Source(chat: chat, turns: turns, lines: lines, turnLines: turnLines)
    }

    /// Main-chain line indexes from root to leaf across compactions, without boundaries and summaries.
    private static func fullChain(_ lines: [Line]) -> [Int] {
        var indexByUUID: [String: Int] = [:]
        for (index, line) in lines.enumerated() where line.isMain {
            indexByUUID[line.uuid!] = index
        }
        guard let leaf = lines.lastIndex(where: { $0.isMain && MergeEngine.leafTypes.contains($0.type) }) else { return [] }

        var chain: [Int] = []
        var visited: Set<String> = []
        var current: Int? = leaf
        while let index = current, let uuid = lines[index].uuid, visited.insert(uuid).inserted {
            let json = lines[index].json
            let isBoundary = json["subtype"] as? String == "compact_boundary"
            if !isBoundary && json["isCompactSummary"] as? Bool != true {
                chain.append(index)
            }
            let parent = (json["parentUuid"] as? String) ?? (isBoundary ? json["logicalParentUuid"] as? String : nil)
            current = parent.flatMap { indexByUUID[$0] }
        }
        return chain.reversed()
    }

    /// A message typed by the user (or a slash command), as opposed to tool results and reminders.
    private static func isPrompt(_ line: Line) -> Bool {
        guard line.type == "user", line.json["isMeta"] as? Bool != true,
              let message = line.json["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String {
            return isPromptText(text)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return false }
        return blocks.contains { $0["type"] as? String == "text" && isPromptText($0["text"] as? String ?? "") }
    }

    private static func isPromptText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.hasPrefix("<local-command")
            && !trimmed.hasPrefix("<system-reminder>")
            && !trimmed.hasPrefix("<task-notification>")
            && !trimmed.hasPrefix("This session is being continued")
    }

    private static func makeTurn(id: Int, lines: [Line]) -> Turn {
        var prompt = ""
        var replies: [String] = []
        var messages = 0
        for line in lines {
            guard let message = line.json["message"] as? [String: Any] else { continue }
            if line.type == "user" || line.type == "assistant" { messages += 1 }
            let texts: [String]
            if let content = message["content"] as? String {
                texts = [content]
            } else {
                texts = (message["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
            }
            if line.type == "user", prompt.isEmpty, isPrompt(line) {
                // IDE notes (<ide_opened_file>…) come before the words actually typed.
                let typed = texts.first { isPromptText($0) && !$0.hasPrefix("<") } ?? texts.first(where: isPromptText) ?? ""
                prompt = typed.hasPrefix("<command-name>") ? readablePrompt(typed) : cleanPromptText(typed)
            } else if line.type == "assistant" {
                replies.append(contentsOf: texts)
            }
        }
        let reply = replies.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = "UTENTE: \(prompt.prefix(1200))\nCLAUDE: \(reply.prefix(1200))"
        let date = (lines.first?.json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
        return Turn(id: id, prompt: prompt.isEmpty ? "(senza testo)" : prompt, timestamp: date, messageCount: messages, digest: digest)
    }

    private static func readablePrompt(_ text: String) -> String {
        if text.hasPrefix("<command-name>"),
           let start = text.range(of: "<command-name>"), let end = text.range(of: "</command-name>") {
            var command = String(text[start.upperBound..<end.lowerBound])
            if let a = text.range(of: "<command-args>"), let b = text.range(of: "</command-args>"), a.upperBound <= b.lowerBound {
                command += " " + text[a.upperBound..<b.lowerBound]
            }
            return command
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writing

    static func split(_ source: Source, topics: [Topic], configDirs: [URL]) throws -> [Result] {
        let fm = FileManager.default
        let chat = source.chat
        let aliases = MergeEngine.sideDirPaths(of: chat)

        struct Pending {
            let id: String
            let temp: URL
            let final: URL
            let sideDir: URL
            let topic: Topic
            let count: Int
        }
        var pending: [Pending] = []
        func discard() { for item in pending { try? fm.removeItem(at: item.temp) } }

        for topic in topics {
            let turns = topic.turns.filter { source.turnLines.indices.contains($0) }.sorted()
            guard !turns.isEmpty else { continue }

            let newID = UUID().uuidString.lowercased()
            let projectDir = Workspaces.encodedName(for: topic.folder)
            let targetDir = ClaudePaths.projects.appendingPathComponent(projectDir)
            let sideDir = targetDir.appendingPathComponent(newID)
            let temp = targetDir.appendingPathComponent(".\(newID).jsonl.partial")

            do {
                try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                let records = buildRecords(source, turns: turns, topic: topic, newID: newID, sideDir: sideDir, aliases: aliases)
                try MergeEngine.write(records, to: temp)
                let count = try MergeEngine.verify(temp)
                pending.append(Pending(id: newID, temp: temp, final: targetDir.appendingPathComponent("\(newID).jsonl"), sideDir: sideDir, topic: topic, count: count))
            } catch {
                try? fm.removeItem(at: temp)
                discard()
                throw ChatOperationError.io("“\(topic.title)”: \(error.localizedDescription)")
            }
        }
        guard !pending.isEmpty else {
            throw ChatOperationError.io("Nessun argomento ha turni assegnati")
        }

        var results: [Result] = []
        for item in pending {
            MergeEngine.copySideFiles(of: chat, to: item.sideDir, newID: item.id)
            MergeEngine.copyFileHistory(from: chat.id, to: item.id, configDirs: configDirs)
            try fm.moveItem(at: item.temp, to: item.final)
            let projectDir = item.final.deletingLastPathComponent().lastPathComponent
            try ChatOperations.rename(
                ChatSession(id: item.id, fileURL: item.final, projectDir: projectDir, modifiedAt: Date(), sizeBytes: 0),
                to: item.topic.title
            )
            results.append(Result(
                sessionID: item.id,
                fileURL: item.final,
                projectDir: projectDir,
                title: item.topic.title,
                folder: item.topic.folder,
                messageCount: item.count
            ))
        }
        return results
    }

    private static func buildRecords(
        _ source: Source,
        turns: [Int],
        topic: Topic,
        newID: String,
        sideDir: URL,
        aliases: [String]
    ) -> [[String: Any]] {
        let chat = source.chat
        var records: [[String: Any]] = []
        var previous: String?
        if let summary = topic.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            let intro = """
            This session is being continued from a previous conversation that was split by topic in AI Switchboard. \
            The original conversation was “\(chat.displayTitle)”; this chat keeps only the part about “\(topic.title)”. \
            The summary below covers the context from the original conversation that matters for this topic.
            """
            let opening = summaryRecords(intro: intro, summary: summary, folder: topic.folder, sessionID: newID)
            records = opening.records
            previous = opening.lastUUID
        }

        var included: Set<String> = []
        for turn in turns {
            for index in source.turnLines[turn] {
                guard var json = reparse(source.lines[index], chat: chat, sideDir: sideDir, aliases: aliases) else { continue }
                json["parentUuid"] = previous.map { $0 as Any } ?? NSNull()
                json["sessionId"] = newID
                if json["cwd"] != nil { json["cwd"] = topic.folder }
                previous = json["uuid"] as? String
                included.insert(previous ?? "")
                records.append(json)
            }
        }

        // Old-style subagent transcripts and rewind snapshots of the kept messages.
        for line in source.lines where line.isSidechain || (line.type.hasPrefix("file-history-") && included.contains(line.json["messageId"] as? String ?? "")) {
            guard var json = reparse(line, chat: chat, sideDir: sideDir, aliases: aliases) else { continue }
            if json["sessionId"] != nil { json["sessionId"] = newID }
            if line.isSidechain, json["cwd"] != nil { json["cwd"] = topic.folder }
            records.append(json)
        }
        return records
    }

    /// Opening of a chat that starts from a summary, in the format Claude Code writes after a
    /// compaction: a boundary (the chain root) and the summary as a user message.
    static func summaryRecords(intro: String, summary: String, folder: String, sessionID: String) -> (records: [[String: Any]], lastUUID: String) {
        let now = isoFormatter.string(from: Date())
        let boundaryID = UUID().uuidString.lowercased()
        let summaryID = UUID().uuidString.lowercased()
        let records: [[String: Any]] = [
            [
                "parentUuid": NSNull(),
                "isSidechain": false,
                "type": "system",
                "subtype": "compact_boundary",
                "content": "Conversation compacted",
                "isMeta": false,
                "timestamp": now,
                "uuid": boundaryID,
                "level": "info",
                "compactMetadata": ["trigger": "manual", "preTokens": 0],
                "userType": "external",
                "cwd": folder,
                "sessionId": sessionID,
            ],
            [
                "parentUuid": boundaryID,
                "isSidechain": false,
                "type": "user",
                "message": ["role": "user", "content": "\(intro)\n\n\(summary)"],
                "isVisibleInTranscriptOnly": true,
                "isCompactSummary": true,
                "uuid": summaryID,
                "timestamp": now,
                "userType": "external",
                "cwd": folder,
                "sessionId": sessionID,
            ],
        ]
        return (records, summaryID)
    }

    /// The line with side-folder paths pointing to the new chat's folder.
    private static func reparse(_ line: Line, chat: ChatSession, sideDir: URL, aliases: [String]) -> [String: Any]? {
        guard line.raw.contains(chat.id) else { return line.json }
        var text = line.raw
        for alias in aliases where text.contains(alias) {
            text = text.replacingOccurrences(of: alias, with: sideDir.path)
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

// MARK: - AI help

/// Runs Claude Code in print mode (Haiku, no tools, nothing saved) with one of the accounts.
enum ClaudeAssistant {
    static func ask(_ prompt: String, account: ClaudeAccount?) async throws -> String {
        guard let binary = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map({ NSString(string: $0).expandingTildeInPath })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ChatOperationError.io("Non trovo il comando claude")
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-p", "--model", "haiku", "--no-session-persistence", "--tools", ""]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var environment = ProcessInfo.processInfo.environment
            if let account, !account.isDefault {
                environment["CLAUDE_CONFIG_DIR"] = account.configDir.path
            }
            process.environment = environment

            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()

            // Write on another thread so a full output pipe can't block us.
            let payload = Data(prompt.utf8)
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: payload)
                try? input.fileHandleForWriting.close()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !text.isEmpty else {
                let message = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self)
                throw ChatOperationError.io("Claude non ha risposto: \(message.prefix(300))")
            }
            return text
        }.value
    }

    struct ProposedTopic: Decodable {
        let title: String
        let turns: [Int]
    }

    /// Asks Claude to group the turns of a chat into topics.
    static func proposeTopics(for turns: [SplitEngine.Turn], account: ClaudeAccount?) async throws -> [ProposedTopic] {
        let list = turns.map { "#\($0.id): \($0.prompt.replacingOccurrences(of: "\n", with: " ").prefix(240))" }
        let prompt = """
        Questa è la lista dei messaggi che un utente ha scritto in una lunga conversazione con un assistente AI, \
        numerati in ordine. Raggruppali per argomento, in modo da dividere la conversazione in chat più piccole \
        e focalizzate.

        Regole:
        - da 2 a 8 argomenti, ciascuno con un titolo breve in italiano (max 5 parole);
        - ogni messaggio va in almeno un argomento; un messaggio di contesto generale può stare in più argomenti;
        - i messaggi brevi di conferma ("ok", "procedi", "perfetto") vanno con l'argomento del messaggio precedente;
        - rispondi SOLO con JSON valido, senza testo prima o dopo, in questo formato:
        {"topics":[{"title":"...","turns":[0,1,2]}]}

        Messaggi:
        \(list.joined(separator: "\n"))
        """
        let answer = try await ask(prompt, account: account)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              let data = String(answer[start...end]).data(using: .utf8) else {
            throw ChatOperationError.io("Risposta non valida da Claude")
        }
        struct Envelope: Decodable { let topics: [ProposedTopic] }
        let topics = try JSONDecoder().decode(Envelope.self, from: data).topics
        let valid = Set(turns.map(\.id))
        return topics
            .map { ProposedTopic(title: $0.title, turns: $0.turns.filter(valid.contains)) }
            .filter { !$0.turns.isEmpty }
    }

    /// Context summary to put at the start of a topic's chat.
    static func summary(of source: SplitEngine.Source, topic: String, turns: [Int], account: ClaudeAccount?) async throws -> String {
        let kept = Set(turns)
        // Keep the transcript within a comfortable size: long chats get shorter excerpts per turn.
        let perTurn = max(300, 160_000 / max(1, source.turns.count))
        let parts = source.turns.map { turn in
            let marker = kept.contains(turn.id) ? " [IN QUESTO ARGOMENTO]" : ""
            return "#\(turn.id)\(marker)\n\(turn.digest.prefix(perTurn))"
        }
        let prompt = """
        Una lunga conversazione tra un utente e Claude (assistente di programmazione e lavoro) viene divisa in \
        più chat, una per argomento. Questa nuova chat riguarda l'argomento “\(topic)” e conterrà solo i turni \
        marcati [IN QUESTO ARGOMENTO].

        Scrivi un riassunto, in italiano, del contesto della conversazione originale utile a proseguire questo \
        argomento: obiettivo, decisioni prese, file, percorsi, comandi e configurazioni coinvolti, stato attuale \
        e cose rimaste aperte. Includi quello che è emerso negli altri argomenti solo se serve a capire questo. \
        Usa elenchi puntati, massimo 400 parole, nessuna introduzione.

        Conversazione:
        \(parts.joined(separator: "\n\n"))
        """
        return try await ask(prompt, account: account)
    }
}
