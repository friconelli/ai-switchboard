import Foundation

/// Short descriptions of what each chat is about, written by Claude (Haiku) and cached.
/// A description is written again once the chat has a few more prompts than when it was made.
final class DescriptionCache {
    struct Entry: Codable {
        let text: String
        let promptCount: Int
        let generatedAt: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private let url = ClaudePaths.appSupport.appendingPathComponent("descriptions.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func needsDescription(_ chat: ChatSession) -> Bool {
        guard chat.promptCount > 0 else { return false }
        guard let entry = entries[chat.id] else { return true }
        return chat.promptCount - entry.promptCount >= 3
    }

    func store(_ texts: [String: String], chats: [ChatSession]) {
        for chat in chats {
            guard let text = texts[chat.id] else { continue }
            entries[chat.id] = Entry(text: text, promptCount: chat.promptCount, generatedAt: Date())
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func set(_ text: String, forChat id: String, promptCount: Int) {
        entries[id] = Entry(text: text, promptCount: promptCount, generatedAt: Date())
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func forget(_ id: String) {
        entries[id] = nil
    }
}

enum DescriptionWriter {
    /// Describes a few chats in one request; returns id → description.
    static func describe(_ chats: [ChatSession], account: ClaudeAccount?) async throws -> [String: String] {
        var byShortID: [String: String] = [:]
        let blocks: [String] = chats.compactMap { chat in
            guard let source = try? SplitEngine.analyze(chat) else { return nil }
            let short = String(chat.id.prefix(8))
            byShortID[short] = chat.id
            var prompts = ""
            for turn in source.turns where prompts.count < 5000 {
                prompts += "- " + cleanPromptText(turn.prompt).prefix(180) + "\n"
            }
            let ending = source.turns.suffix(2).map { String($0.digest.prefix(1500)) }.joined(separator: "\n")
            return """
            ### \(short) — \(chat.displayTitle) (cartella \(chat.projectName))
            Richieste dell'utente:
            \(prompts)
            Ultimi scambi:
            \(ending)
            """
        }
        guard !blocks.isEmpty else { return [:] }

        let prompt = """
        Per ciascuna conversazione qui sotto (tra un utente e Claude, assistente di programmazione e lavoro) \
        scrivi una descrizione in italiano di una o due frasi, massimo 200 caratteri: di cosa tratta \
        concretamente (progetto, sito, file, obiettivo) e a che punto è arrivata. Niente preamboli, niente \
        "In questa conversazione". Rispondi SOLO con JSON: {"<id>":"descrizione", ...}

        \(blocks.joined(separator: "\n\n"))
        """
        let answer = try await ClaudeAssistant.ask(prompt, account: account)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              let data = String(answer[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw ChatOperationError.io("Risposta non valida da Claude")
        }
        var result: [String: String] = [:]
        for (key, text) in raw {
            if let id = byShortID[String(key.prefix(8))] {
                result[id] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}
