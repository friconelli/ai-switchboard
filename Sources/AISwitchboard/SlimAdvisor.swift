import Foundation

/// What slimming a chat would gain right now, worked out from the file itself and cached.
///
/// Usage figures come from the responses Claude Code recorded, so they never change when a
/// chat is slimmed. This is measured on the file as it is: once a chat is slim it reads zero,
/// and a suggestion to slim it goes away.
struct SlimEntry: Codable, Sendable {
    let size: Int64
    let modified: Date
    /// Tokens Claude no longer rereads on resume, with the categories that are on by default.
    let tokens: Int
    let bytes: Int
    /// Context Claude rereads on resume: the size Claude Code recorded when known, reduced by what
    /// was slimmed since, otherwise estimated from the text.
    let context: Int

    /// Worth suggesting: at least `minTokens`, and 5% of the context.
    var isWorthIt: Bool { tokens >= SlimAdvisor.minTokens && tokens * 20 >= context }

    func matches(_ chat: ChatSession) -> Bool {
        size == chat.sizeBytes && abs(modified.timeIntervalSince(chat.modifiedAt)) < 1
    }
}

enum SlimAdvisor {
    /// Below this a slimming is not suggested.
    static let minTokens = 5_000
    /// Below this the slim sheet says the chat is already slim.
    static let sheetMinTokens = 1_000
    static let sheetMinBytes = 1_000_000

    private static let url = ClaudePaths.appSupport.appendingPathComponent("slim-cache-v1.json")

    static func load() -> [String: SlimEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: SlimEntry].self, from: data) else { return [:] }
        return entries
    }

    static func save(_ entries: [String: SlimEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Chats whose context could be big enough for slimming to matter; the others are not read.
    static func isCandidate(_ chat: ChatSession, measuredContext: Int) -> Bool {
        measuredContext >= 30_000 || chat.sizeBytes >= 5_000_000
    }

    /// Savings scale: the text-based estimate runs high against what Claude Code measured.
    static func factor(measured: Int, estimated: Int) -> Double {
        measured > 0 && estimated > 0 ? min(1, Double(measured) / Double(estimated)) : 1
    }

    /// Reads the file as it is now. `measured` is the context Claude Code recorded (0 if unknown).
    static func evaluate(_ chat: ChatSession, measured: Int) -> SlimEntry? {
        guard let values = try? chat.fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate,
              let source = try? SlimEngine.analyze(chat) else { return nil }
        let defaults = Set(SlimEngine.Category.allCases.filter(\.defaultOn))
        let plan = SlimEngine.plan(source, enabled: defaults)
        let scale = factor(measured: measured, estimated: source.contextTokens)
        return SlimEntry(
            size: Int64(size),
            modified: modified,
            tokens: Int(Double(plan.tokensSaved) * scale),
            bytes: plan.bytesSaved,
            context: measured > 0 ? measured : source.contextTokens
        )
    }
}
