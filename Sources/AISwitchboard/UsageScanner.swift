import Foundation

enum ModelTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case haiku, sonnet, opus

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Alias accepted by `claude --model`.
    var alias: String { rawValue }

    init?(model: String) {
        let lower = model.lowercased()
        if lower.contains("opus") { self = .opus } else if lower.contains("sonnet") { self = .sonnet } else if lower.contains("haiku") { self = .haiku } else { return nil }
    }
}

/// Token usage and kind of work of one chat, read from the `usage` Claude Code records on
/// every response.
struct ChatUsage: Codable, Sendable {
    var responses = 0
    var inputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    /// Responses per model tier.
    var models: [String: Int] = [:]
    /// Tool calls per tool name.
    var tools: [String: Int] = [:]
    var compactions = 0
    var images = 0
    /// Context size of the latest request: what every new message makes Claude reread.
    var lastContext = 0
    /// Weighted consumption per day (`yyyy-MM-dd`) and tier.
    var daily: [String: [String: Double]] = [:]

    /// Estimated consumption in input-token equivalents: cache writes cost a bit more than
    /// fresh input, cache reads about a tenth, output about five times as much.
    var weighted: Double {
        Double(inputTokens) + Double(cacheWriteTokens) * 1.25 + Double(cacheReadTokens) * 0.1 + Double(outputTokens) * 5
    }

    var cacheReadShare: Double {
        let weight = weighted
        return weight > 0 ? Double(cacheReadTokens) * 0.1 / weight : 0
    }

    var dominantTier: ModelTier? {
        models.max { $0.value < $1.value }.flatMap { ModelTier(rawValue: $0.key) }
    }

    var toolCalls: Int { tools.values.reduce(0, +) }
    var edits: Int { ["Edit", "Write", "MultiEdit", "NotebookEdit"].reduce(0) { $0 + (tools[$1] ?? 0) } }
}

/// Reads token usage from transcripts; cached per file like `ChatIndexer`.
final class UsageScanner {
    private struct CacheEntry: Codable {
        let size: Int64
        let modified: Date
        let usage: ChatUsage
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheURL = ClaudePaths.appSupport.appendingPathComponent("usage-cache-v1.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            cache = decoded
        }
    }

    func scan(_ chats: [ChatSession]) -> [String: ChatUsage] {
        var result: [String: ChatUsage] = [:]
        var fresh: [String: CacheEntry] = [:]
        for chat in chats {
            if let cached = cache[chat.fileURL.path], cached.size == chat.sizeBytes, cached.modified == chat.modifiedAt {
                result[chat.id] = cached.usage
                fresh[chat.fileURL.path] = cached
                continue
            }
            guard let usage = Self.scan(file: chat.fileURL) else { continue }
            result[chat.id] = usage
            fresh[chat.fileURL.path] = CacheEntry(size: chat.sizeBytes, modified: chat.modifiedAt, usage: usage)
        }
        cache = fresh
        if let data = try? JSONEncoder().encode(fresh) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return result
    }

    private static let usageNeedle = Array(#""usage""#.utf8)
    private static let assistantNeedle = Array(#""type":"assistant""#.utf8)
    private static let boundaryNeedle = Array(#""compact_boundary""#.utf8)
    private static let imageNeedle = Array(#""type":"image""#.utf8)
    private static let sidechainNeedle = Array(#""isSidechain":true"#.utf8)

    static func scan(file: URL) -> ChatUsage? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        var usage = ChatUsage()
        // A response is written as one line per content block, all with the same message id
        // and usage: count tools on every line, usage once per id (the last copy is complete).
        var perMessage: [String: (usage: [String: Any], tier: ModelTier?, day: String?)] = [:]
        var order: [String] = []

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ChatIndexer.forEachLine(base: base, count: raw.count) { line, length in
                if ChatIndexer.contains(line, length, boundaryNeedle) {
                    usage.compactions += 1
                    return
                }
                if ChatIndexer.contains(line, length, imageNeedle) {
                    usage.images += 1
                }
                guard ChatIndexer.contains(line, length, assistantNeedle),
                      ChatIndexer.contains(line, length, usageNeedle),
                      !ChatIndexer.contains(line, length, sidechainNeedle) else { return }
                let lineData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none)
                guard let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let message = json["message"] as? [String: Any],
                      let id = message["id"] as? String,
                      let tokens = message["usage"] as? [String: Any] else { return }
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    if let name = block["name"] as? String { usage.tools[name, default: 0] += 1 }
                }
                if perMessage[id] == nil { order.append(id) }
                let day = (json["timestamp"] as? String).map { String($0.prefix(10)) }
                perMessage[id] = (tokens, ModelTier(model: message["model"] as? String ?? ""), day)
            }
        }

        for id in order {
            guard let entry = perMessage[id] else { continue }
            let tokens = entry.usage
            let input = tokens["input_tokens"] as? Int ?? 0
            let read = tokens["cache_read_input_tokens"] as? Int ?? 0
            let write = tokens["cache_creation_input_tokens"] as? Int ?? 0
            let output = tokens["output_tokens"] as? Int ?? 0
            usage.responses += 1
            usage.inputTokens += input
            usage.cacheReadTokens += read
            usage.cacheWriteTokens += write
            usage.outputTokens += output
            usage.lastContext = input + read + write
            let tier = entry.tier?.rawValue ?? "altro"
            usage.models[tier, default: 0] += 1
            if let day = entry.day {
                let weight = Double(input) + Double(write) * 1.25 + Double(read) * 0.1 + Double(output) * 5
                usage.daily[day, default: [:]][tier, default: 0] += weight
            }
        }
        return usage
    }
}

// MARK: - Advice

enum ModelAdvisor {
    struct Recommendation: Sendable {
        let tier: ModelTier
        let reason: String
    }

    /// The model that fits the kind of work done in a chat, judged from how tools were used.
    static func recommend(_ usage: ChatUsage, prompts: Int) -> Recommendation? {
        guard usage.responses >= 3 else { return nil }
        let prompts = max(1, prompts)
        let toolsPerPrompt = Double(usage.toolCalls) / Double(prompts)
        let averageOutput = usage.outputTokens / max(1, usage.responses)

        if usage.edits >= 60 || (usage.edits >= 25 && usage.compactions >= 2) {
            return Recommendation(tier: .opus, reason: "sviluppo lungo con \(usage.edits) modifiche ai file")
        }
        if usage.edits == 0 && toolsPerPrompt < 3 && averageOutput < 700 {
            return Recommendation(tier: .haiku, reason: "domande e lavori brevi, quasi senza strumenti")
        }
        if usage.edits == 0 {
            return Recommendation(tier: .sonnet, reason: "operazioni, ricerche e controlli senza modifiche al codice")
        }
        return Recommendation(tier: .sonnet, reason: "sviluppo di media durata")
    }

    struct Insight: Identifiable, Sendable {
        enum Action: Sendable { case slim, split }
        enum Kind: Sendable { case slimGain, compactions, modelDown, modelUp }

        var id: String { "\(chatID)-\(kind)" }
        let chatID: String
        let kind: Kind
        let text: String
        let action: Action?
        /// Worth doing now: these light the bulb. Model advice is only a suggestion.
        var isMajor: Bool { kind == .slimGain || kind == .compactions }
    }

    /// `context`: what Claude rereads now (reduced by slimming). `slim`: what slimming would still
    /// gain on the file as it is; without it nothing is suggested, so a slim chat shows no advice.
    static func insights(for chat: ChatSession, usage: ChatUsage, context: Int, slim: SlimEntry?) -> [Insight] {
        var result: [Insight] = []
        func add(_ kind: Insight.Kind, _ text: String, _ action: Insight.Action?) {
            result.append(Insight(chatID: chat.id, kind: kind, text: text, action: action))
        }

        if let slim, slim.isWorthIt {
            add(.slimGain, "Snellendo la chat Claude rilegge ~\(slim.tokens / 1000)k token in meno a ogni messaggio (ora ~\(context / 1000)k).", .slim)
        }
        if usage.compactions >= 2 && context >= 100_000 {
            add(.compactions, "Compattata \(usage.compactions) volte e ancora ~\(context / 1000)k token di contesto: conviene dividerla per argomenti.", .split)
        }
        if let used = usage.dominantTier, let recommended = recommend(usage, prompts: chat.promptCount) {
            if recommended.tier.order < used.order {
                add(.modelDown, "Fatta con \(used.label), ma è \(recommended.reason): \(recommended.tier.label) basta e consuma meno quota.", nil)
            } else if recommended.tier.order > used.order {
                add(.modelUp, "Fatta con \(used.label), ma è \(recommended.reason): con \(recommended.tier.label) servirebbero meno giri e correzioni.", nil)
            }
        }
        return result
    }
}

extension ModelTier {
    var order: Int {
        switch self {
        case .haiku: return 0
        case .sonnet: return 1
        case .opus: return 2
        }
    }
}
