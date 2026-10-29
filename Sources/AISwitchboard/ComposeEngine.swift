import Foundation

/// Builds a new chat for a request, already informed by the user's past chats: Claude picks
/// the relevant chats, a folder, a title and a model, then writes a context summary that opens
/// the new chat (same format as a compaction summary, so `claude --resume` loads it).
enum ComposeEngine {
    struct SuggestedChat: Sendable {
        let id: String
        let reason: String
    }

    struct Proposal: Sendable {
        var title: String
        var folder: String?
        var model: ModelTier?
        var modelReason: String
        var chats: [SuggestedChat]
    }

    /// Asks Claude which chats, folder and model fit the request.
    static func propose(
        request: String,
        chats: [ChatSession],
        folders: [WorkFolder],
        descriptions: [String: String],
        account: ClaudeAccount?
    ) async throws -> Proposal {
        let recent = chats.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(150)
        var byShortID: [String: String] = [:]
        let chatLines = recent.map { chat -> String in
            let short = String(chat.id.prefix(8))
            byShortID[short] = chat.id
            let about = (descriptions[chat.id] ?? chat.preview ?? "").prefix(220)
            return "\(short) | \(chat.displayTitle.prefix(80)) | \(chat.projectName) | \(about)"
        }
        let folderLines = folders.map { folder in
            "\(folder.kind == .area ? "area" : "progetto")\(folder.context.map { " \($0)" } ?? ""): \(folder.path)"
        }

        let prompt = """
        Un utente vuole iniziare una nuova conversazione con Claude Code (assistente di programmazione e \
        lavoro) e vuole che parta già informata dalle sue conversazioni passate.

        RICHIESTA:
        \(request)

        Scegli:
        - "chats": da 0 a 5 conversazioni passate davvero utili per questa richiesta (id di 8 caratteri), \
        ciascuna con il motivo in poche parole. Meglio nessuna che una poco pertinente.
        - "folder": la cartella di lavoro più adatta, copiata esattamente dalla lista; stringa vuota se nessuna va bene.
        - "title": titolo breve in italiano per la nuova chat (max 5 parole).
        - "model": "haiku" per domande e lavori brevi e semplici, "sonnet" per sviluppo e lavoro quotidiano, \
        "opus" per progetti lunghi, complessi o di architettura; "model_reason": motivo in poche parole.

        Rispondi SOLO con JSON valido in questo formato:
        {"title":"...","folder":"...","model":"sonnet","model_reason":"...","chats":[{"id":"abcd1234","reason":"..."}]}

        CARTELLE:
        \(folderLines.joined(separator: "\n"))

        CONVERSAZIONI (id | titolo | progetto | descrizione o prima richiesta):
        \(chatLines.joined(separator: "\n"))
        """

        let answer = try await ClaudeAssistant.ask(prompt, account: account)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              let data = String(answer[start...end]).data(using: .utf8) else {
            throw ChatOperationError.io("Risposta non valida da Claude")
        }
        struct Raw: Decodable {
            struct Item: Decodable { let id: String; let reason: String? }
            let title: String?
            let folder: String?
            let model: String?
            let model_reason: String?
            let chats: [Item]?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let validFolders = Set(folders.map(\.path))
        return Proposal(
            title: raw.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Nuova chat",
            folder: raw.folder.flatMap { validFolders.contains($0) ? $0 : nil },
            model: raw.model.flatMap { ModelTier(rawValue: $0.lowercased()) },
            modelReason: raw.model_reason ?? "",
            chats: (raw.chats ?? []).compactMap { item in
                byShortID[String(item.id.prefix(8))].map { SuggestedChat(id: $0, reason: item.reason ?? "") }
            }
        )
    }

    /// The context the new chat starts from: only what the past chats say about this request.
    static func summary(request: String, sources: [SplitEngine.Source], account: ClaudeAccount?) async throws -> String {
        let totalTurns = max(1, sources.reduce(0) { $0 + $1.turns.count })
        let perTurn = max(250, 150_000 / totalTurns)
        let material = sources.map { source in
            let turns = source.turns.map { "#\($0.id)\n\($0.digest.prefix(perTurn))" }
            return "=== CONVERSAZIONE: \(source.chat.displayTitle) (cartella \(source.chat.workingDirectory)) ===\n" + turns.joined(separator: "\n\n")
        }
        let prompt = """
        Un utente inizia una nuova conversazione con Claude Code per questa richiesta:

        \(request)

        Qui sotto ci sono conversazioni passate collegate. Scrivi, in italiano, il contesto con cui la nuova \
        conversazione deve partire: solo ciò che serve per questa richiesta. Fatti, decisioni già prese e perché, \
        file, percorsi, comandi, configurazioni, accessi (mai password o chiavi), preferenze dell'utente, \
        problemi già incontrati e come sono stati risolti, cose rimaste aperte. Niente di non pertinente. \
        Usa titoletti brevi ed elenchi puntati, massimo 600 parole, nessuna introduzione.

        \(material.joined(separator: "\n\n"))
        """
        return try await ClaudeAssistant.ask(prompt, account: account)
    }

    /// Writes the new chat: an opening summary and nothing else, ready to be resumed.
    static func create(title: String, folder: String, summary: String, sourceTitles: [String]) throws -> ChatSession {
        let fm = FileManager.default
        let id = UUID().uuidString.lowercased()
        let projectDir = Workspaces.encodedName(for: folder)
        let directory = ClaudePaths.projects.appendingPathComponent(projectDir)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).jsonl")
        let temp = directory.appendingPathComponent(".\(id).jsonl.partial")

        let intro = """
        This session is being continued from a previous conversation. It was prepared in AI Switchboard from \
        the user's earlier conversations (\(sourceTitles.map { "“\($0)”" }.joined(separator: ", "))): \
        the summary below holds what matters for the request the user is about to make.
        """
        let opening = SplitEngine.summaryRecords(intro: intro, summary: summary, folder: folder, sessionID: id)
        try MergeEngine.write(opening.records, to: temp)
        do {
            _ = try MergeEngine.verify(temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        try fm.moveItem(at: temp, to: url)
        let chat = ChatSession(id: id, fileURL: url, projectDir: projectDir, cwd: folder, title: title, isCustomTitle: true, modifiedAt: Date(), sizeBytes: 0)
        try ChatOperations.rename(chat, to: title)
        return chat
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
