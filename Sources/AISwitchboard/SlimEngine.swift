import Foundation

/// Slims a transcript in place, keeping the same chat (same id, same `/resume` entry).
///
/// Some of what a transcript holds is never reloaded by Claude Code: internal request logs,
/// metadata repeated on every turn, automatic reminders, branches undone with rewind. Other
/// parts are reloaded but only temporary: screenshots, very long tool outputs, outputs made
/// obsolete by the same command or file read later, internal reasoning. Each category can be
/// switched on separately.
///
/// Tool calls are never removed, only their results shortened, so every call keeps its answer.
/// Removed messages are bridged by re-parenting their children. The slimmed copy is verified
/// (same conversation, in the same order, minus what was removed; every tool call paired) and
/// only then replaces the original, which goes to the Trash.
enum SlimEngine {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case technical, images, longOutputs, repeated, thinking, pastedImages, compacted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .technical: return "Dati tecnici e promemoria automatici"
            case .images: return "Screenshot, immagini e PDF letti dai tool"
            case .longOutputs: return "Output lunghi dei tool"
            case .repeated: return "Output ripetuti o superati"
            case .thinking: return "Ragionamenti interni"
            case .pastedImages: return "Immagini incollate da te"
            case .compacted: return "Storia già compattata"
            }
        }

        var detail: String {
            switch self {
            case .technical:
                return "Log interni delle richieste, metadati ripetuti a ogni turno, promemoria e notifiche automatiche, rami annullati con rewind. Claude non li rilegge."
            case .images:
                return "Sostituiti da una nota. Claude li ha già visti e descritti; i file originali restano dove sono."
            case .longOutputs:
                return "Oltre 4.000 caratteri tiene inizio e fine: log di build, letture di file, risultati di ricerca."
            case .repeated:
                return "Se lo stesso file viene riletto o lo stesso comando rieseguito, resta solo l'ultimo risultato."
            case .thinking:
                return "Il ragionamento che Claude fa prima di rispondere; le risposte restano. L'ultimo turno non viene toccato."
            case .pastedImages:
                return "Screenshot e immagini che hai incollato nei messaggi. Le tue parole restano."
            case .compacted:
                return "La parte prima dell'ultima compattazione: Claude ne usa solo il riassunto. Perdi l'archivio (e la possibilità di dividerla)."
            }
        }

        var defaultOn: Bool {
            switch self {
            case .technical, .images, .longOutputs, .repeated, .thinking: return true
            case .pastedImages, .compacted: return false
            }
        }

        var symbol: String {
            switch self {
            case .technical: return "gearshape.2"
            case .images: return "photo.on.rectangle"
            case .longOutputs: return "text.append"
            case .repeated: return "square.on.square"
            case .thinking: return "brain"
            case .pastedImages: return "photo"
            case .compacted: return "archivebox"
            }
        }
    }

    struct Saving: Sendable {
        var bytes = 0
        /// Estimated tokens no longer sent to Claude when the chat is resumed.
        var tokens = 0
        var items = 0
    }

    struct Plan: Sendable {
        var savings: [Category: Saving] = [:]
        fileprivate var dropped: Set<Int> = []
        fileprivate var edited: [Int: SendableJSON] = [:]

        var bytesSaved: Int { savings.values.reduce(0) { $0 + $1.bytes } }
        var tokensSaved: Int { savings.values.reduce(0) { $0 + $1.tokens } }
    }

    fileprivate struct SendableJSON: @unchecked Sendable {
        var value: [String: Any]
    }

    final class Source: @unchecked Sendable {
        let chat: ChatSession
        let sizeBytes: Int
        /// Estimated tokens Claude reloads on resume (the part after the last compaction).
        let contextTokens: Int
        let hasCompaction: Bool
        fileprivate let lines: [Line]
        fileprivate let fullChain: [String]
        fileprivate let effectiveChain: [String]
        fileprivate let effective: Set<String>
        fileprivate let protected: Set<String>
        fileprivate let lastPromptIndex: Int

        fileprivate init(chat: ChatSession, sizeBytes: Int, contextTokens: Int, lines: [Line], fullChain: [String],
                         effectiveChain: [String], protected: Set<String>, lastPromptIndex: Int) {
            self.chat = chat
            self.sizeBytes = sizeBytes
            self.contextTokens = contextTokens
            self.lines = lines
            self.fullChain = fullChain
            self.effectiveChain = effectiveChain
            self.effective = Set(effectiveChain)
            self.hasCompaction = fullChain.count > effectiveChain.count
            self.protected = protected
            self.lastPromptIndex = lastPromptIndex
        }
    }

    fileprivate struct Line {
        let raw: String
        let json: [String: Any]
        var uuid: String? { json["uuid"] as? String }
        var parent: String? { json["parentUuid"] as? String }
        var type: String { json["type"] as? String ?? "" }
        var isSidechain: Bool { json["isSidechain"] as? Bool == true }
        var isMain: Bool { uuid != nil && !isSidechain }
        var content: [[String: Any]]? { (json["message"] as? [String: Any])?["content"] as? [[String: Any]] }
    }

    /// Internal logs, never part of the conversation.
    private static let logTypes: Set<String> = ["api-request", "api-request-blob", "api-request-shape"]
    /// Metadata where only the latest record matters.
    private static let latestOnlyTypes: Set<String> = [
        "mode", "permission-mode", "atis-latch", "last-prompt", "ai-title", "custom-title", "agent-name",
        "queue-operation", "tools-used",
    ]
    /// Automatic attachments that are regenerated or meaningless after the fact.
    private static let ephemeralAttachments: Set<String> = [
        "hook_success", "total_tokens_reminder", "silent_turn_reminder", "prompt_snapshot",
        "skill_listing", "agent_listing_delta", "mcp_instructions_delta",
    ]
    private static let ephemeralSystem: Set<String> = [
        "turn_duration", "stop_hook_summary", "away_summary", "informational", "api_error",
    ]
    private static let readLikeTools: Set<String> = [
        "Read", "Bash", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "BashOutput",
    ]

    private static let logPrefix = Array(#"{"type":"api-request"#.utf8)
    private static let longLimit = 4000
    private static let imageTokens = 1600

    // MARK: - Reading

    static func analyze(_ chat: ChatSession) throws -> Source {
        let data = try Data(contentsOf: chat.fileURL, options: .alwaysMapped)
        var lines: [Line] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ChatIndexer.forEachLine(base: base, count: raw.count) { pointer, length in
                let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
                // Internal request logs are a third of an archive and only ever dropped whole:
                // their type is enough, no need to parse them.
                if length > logPrefix.count, memcmp(pointer, logPrefix, logPrefix.count) == 0 {
                    var end = logPrefix.count
                    while end < length, bytes[end] != 0x22 { end += 1 }
                    let type = String(decoding: bytes[9..<end], as: UTF8.self)
                    lines.append(Line(raw: String(decoding: bytes, as: UTF8.self), json: ["type": type]))
                    return
                }
                guard let json = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] else { return }
                lines.append(Line(raw: String(decoding: bytes, as: UTF8.self), json: json))
            }
        }

        let index = mainIndex(lines)
        let full = walk(lines, index: index, crossCompactions: true)
        let effective = walk(lines, index: index, crossCompactions: false)

        var protected: Set<String> = []
        for line in lines where line.json["subtype"] as? String == "compact_boundary" {
            if let metadata = line.json["compactMetadata"] { collectUUIDs(metadata, into: &protected) }
        }

        let effectiveSet = Set(effective)
        var tokens = 0
        var lastPrompt = 0
        for (i, line) in lines.enumerated() where line.isMain && effectiveSet.contains(line.uuid!) {
            tokens += contextTokens(line.json)
            if isPrompt(line) { lastPrompt = i }
        }

        return Source(
            chat: chat,
            sizeBytes: data.count,
            contextTokens: tokens,
            lines: lines,
            fullChain: full,
            effectiveChain: effective,
            protected: protected,
            lastPromptIndex: lastPrompt
        )
    }

    private static func mainIndex(_ lines: [Line]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (i, line) in lines.enumerated() where line.isMain { index[line.uuid!] = i }
        return index
    }

    /// uuids from the last main message back to the root; across compactions or up to the last one.
    private static func walk(_ lines: [Line], index: [String: Int], crossCompactions: Bool) -> [String] {
        guard let leaf = lines.lastIndex(where: { $0.isMain && MergeEngine.leafTypes.contains($0.type) }) else { return [] }
        var chain: [String] = []
        var seen: Set<String> = []
        var current: Int? = leaf
        while let i = current, let uuid = lines[i].uuid, seen.insert(uuid).inserted {
            chain.append(uuid)
            var parent = lines[i].parent
            if parent == nil, crossCompactions, lines[i].json["subtype"] as? String == "compact_boundary" {
                parent = lines[i].json["logicalParentUuid"] as? String
            }
            current = parent.flatMap { index[$0] }
        }
        return chain.reversed()
    }

    private static func collectUUIDs(_ value: Any, into set: inout Set<String>) {
        if let string = value as? String, string.count == 36, string.filter({ $0 == "-" }).count == 4 {
            set.insert(string)
        } else if let array = value as? [Any] {
            for item in array { collectUUIDs(item, into: &set) }
        } else if let dict = value as? [String: Any] {
            for item in dict.values { collectUUIDs(item, into: &set) }
        }
    }

    private static func isPrompt(_ line: Line) -> Bool {
        guard line.type == "user", line.json["isMeta"] as? Bool != true,
              let message = line.json["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        let blocks = line.content ?? []
        return !blocks.contains { $0["type"] as? String == "tool_result" } && blocks.contains { $0["type"] as? String == "text" }
    }

    // MARK: - Planning

    static func plan(_ source: Source, enabled: Set<Category>) -> Plan {
        var plan = Plan()
        let lines = source.lines
        let fullSet = Set(source.fullChain)

        func credit(_ category: Category, bytes: Int, tokens: Int = 0) {
            plan.savings[category, default: Saving()].bytes += bytes
            plan.savings[category, default: Saving()].tokens += tokens
            plan.savings[category, default: Saving()].items += 1
        }
        func inContext(_ line: Line) -> Bool { line.uuid.map(source.effective.contains) ?? false }
        func drop(_ i: Int, _ category: Category) {
            guard plan.dropped.insert(i).inserted else { return }
            let line = lines[i]
            // Automatic reminders are not all sent to Claude: claim no token saving for them.
            let tokens = category != .technical && inContext(line) ? contextTokens(line.json) : 0
            credit(category, bytes: line.raw.utf8.count + 1, tokens: tokens)
        }

        // Lines that go entirely.
        if enabled.contains(.technical) {
            var latest: [String: Int] = [:]
            for (i, line) in lines.enumerated() where latestOnlyTypes.contains(line.type) && line.uuid == nil {
                latest[line.type] = i
            }
            for (i, line) in lines.enumerated() {
                if line.uuid == nil {
                    if logTypes.contains(line.type) || (latestOnlyTypes.contains(line.type) && latest[line.type] != i) {
                        drop(i, .technical)
                    }
                    continue
                }
                guard line.isMain, let uuid = line.uuid, !source.protected.contains(uuid) else { continue }
                if !fullSet.contains(uuid) {
                    drop(i, .technical)
                } else if line.type == "attachment",
                          let kind = (line.json["attachment"] as? [String: Any])?["type"] as? String,
                          ephemeralAttachments.contains(kind) {
                    drop(i, .technical)
                } else if line.type == "system", let subtype = line.json["subtype"] as? String, ephemeralSystem.contains(subtype) {
                    drop(i, .technical)
                }
            }
        }

        if enabled.contains(.compacted), source.hasCompaction {
            var kept: Set<String> = source.effective.union(source.protected)
            for (i, line) in lines.enumerated() where line.isMain && !kept.contains(line.uuid!) {
                drop(i, .compacted)
            }
            kept.formUnion(source.protected)
            for (i, line) in lines.enumerated() where line.type.hasPrefix("file-history-") {
                if let id = line.json["messageId"] as? String, !kept.contains(id) { drop(i, .compacted) }
            }
        }

        // Tool calls whose result is superseded by a later identical call.
        var superseded: Set<String> = []
        if enabled.contains(.repeated) {
            var keyByID: [String: String] = [:]
            for line in lines where line.type == "assistant" {
                for block in line.content ?? [] where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String,
                          readLikeTools.contains(name) || name.contains("read_") || name.contains("get_") || name.contains("list_") else { continue }
                    let input = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:], options: [.sortedKeys])) ?? Data()
                    keyByID[id] = name + String(decoding: input, as: UTF8.self)
                }
            }
            var lastByKey: [String: String] = [:]
            var order: [String] = []
            let chainIndex = mainIndex(lines)
            for uuid in source.fullChain {
                guard let i = chainIndex[uuid], lines[i].type == "user" else { continue }
                for block in lines[i].content ?? [] where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String, let key = keyByID[id] else { continue }
                    if let previous = lastByKey[key] { order.append(previous) }
                    lastByKey[key] = id
                }
            }
            superseded = Set(order)
        }

        // Content that gets shortened.
        for (i, line) in lines.enumerated() where !plan.dropped.contains(i) && line.isMain {
            guard var blocks = line.content else { continue }
            let contextual = inContext(line)
            var json = line.json
            var changed = false

            if line.type == "assistant", enabled.contains(.thinking), i < source.lastPromptIndex {
                let thinking = blocks.filter { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
                if !thinking.isEmpty {
                    let size = thinking.reduce(0) { $0 + jsonSize($1) }
                    let thinkingTokens = contextual ? thinking.reduce(0) { $0 + blockTokens($1) } : 0
                    if thinking.count == blocks.count {
                        if !source.protected.contains(line.uuid!) {
                            plan.dropped.insert(i)
                            credit(.thinking, bytes: line.raw.utf8.count + 1, tokens: thinkingTokens)
                        }
                        continue
                    }
                    blocks.removeAll { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
                    credit(.thinking, bytes: size, tokens: thinkingTokens)
                    changed = true
                }
            }

            if line.type == "user" {
                for b in blocks.indices {
                    let type = blocks[b]["type"] as? String
                    if type == "tool_result" {
                        let id = blocks[b]["tool_use_id"] as? String ?? ""
                        let before = jsonSize(blocks[b])
                        if superseded.contains(id), before > 600 {
                            let beforeTokens = blockTokens(blocks[b])
                            blocks[b]["content"] = "[AI Switchboard: output rimosso perché lo stesso comando o file è stato riletto più avanti]"
                            credit(.repeated, bytes: before - jsonSize(blocks[b]), tokens: contextual ? beforeTokens - blockTokens(blocks[b]) : 0)
                            changed = true
                            continue
                        }
                        if enabled.contains(.images), var items = blocks[b]["content"] as? [[String: Any]] {
                            let images = replaceImages(&items)
                            if images > 0 {
                                blocks[b]["content"] = items
                                let after = jsonSize(blocks[b])
                                credit(.images, bytes: before - after, tokens: contextual ? images * imageTokens : 0)
                                changed = true
                            }
                        }
                        if enabled.contains(.longOutputs) {
                            let start = jsonSize(blocks[b])
                            let startTokens = blockTokens(blocks[b])
                            if shortenText(&blocks[b]) {
                                credit(.longOutputs, bytes: start - jsonSize(blocks[b]), tokens: contextual ? startTokens - blockTokens(blocks[b]) : 0)
                                changed = true
                            }
                        }
                    } else if (type == "image" || type == "document"), enabled.contains(.pastedImages) {
                        let before = jsonSize(blocks[b])
                        blocks[b] = ["type": "text", "text": "[AI Switchboard: immagine incollata rimossa]"]
                        credit(.pastedImages, bytes: before - jsonSize(blocks[b]), tokens: contextual ? imageTokens : 0)
                        changed = true
                    }
                }

                // The structured copy of the result, used only to draw the transcript.
                if let result = json["toolUseResult"] {
                    let resultID = blocks.first { $0["type"] as? String == "tool_result" }?["tool_use_id"] as? String ?? ""
                    let size = jsonSize(result)
                    var replacement: Any?
                    var category: Category?
                    if superseded.contains(resultID), size > 600 {
                        replacement = "[output rimosso: ripetuto più avanti]"
                        category = .repeated
                    } else if enabled.contains(.images), let dict = result as? [String: Any], ["image", "pdf"].contains(dict["type"] as? String ?? "") {
                        replacement = "[\(dict["type"] as? String == "pdf" ? "PDF" : "immagine") rimosso da AI Switchboard]"
                        category = .images
                    } else if enabled.contains(.images), var items = result as? [[String: Any]], replaceImages(&items) > 0 {
                        replacement = items
                        category = .images
                    }
                    if replacement == nil, enabled.contains(.longOutputs), size > longLimit * 2 {
                        replacement = "[dettaglio dell'output rimosso da AI Switchboard]"
                        category = .longOutputs
                    }
                    if let replacement, let category {
                        json["toolUseResult"] = replacement
                        credit(category, bytes: size - jsonSize(replacement))
                        changed = true
                    }
                }
            }

            if changed {
                var message = json["message"] as? [String: Any] ?? [:]
                message["content"] = blocks
                json["message"] = message
                plan.edited[i] = SendableJSON(value: json)
            }
        }

        // Children of removed messages hang on the nearest kept ancestor.
        var removedParent: [String: String?] = [:]
        for i in plan.dropped where lines[i].isMain {
            removedParent[lines[i].uuid!] = lines[i].parent
        }
        if !removedParent.isEmpty {
            func resolve(_ uuid: String?) -> String? {
                var current = uuid
                var steps = 0
                while let id = current, let parent = removedParent[id], steps < 1_000_000 {
                    current = parent
                    steps += 1
                }
                return current
            }
            for (i, line) in lines.enumerated() where !plan.dropped.contains(i) {
                var json = plan.edited[i]?.value ?? line.json
                var changed = false
                for key in ["parentUuid", "logicalParentUuid"] {
                    if let parent = json[key] as? String, removedParent[parent] != nil {
                        json[key] = resolve(parent).map { $0 as Any } ?? NSNull()
                        changed = true
                    }
                }
                if changed { plan.edited[i] = SendableJSON(value: json) }
            }
        }
        return plan
    }

    /// Replaces image and document blocks with a note; returns how many were replaced.
    private static func replaceImages(_ items: inout [[String: Any]]) -> Int {
        var count = 0
        for i in items.indices where ["image", "document"].contains(items[i]["type"] as? String ?? "") {
            items[i] = ["type": "text", "text": "[AI Switchboard: immagine rimossa, Claude l'aveva già vista]"]
            count += 1
        }
        return count
    }

    /// Keeps the start and the end of a long tool result.
    private static func shortenText(_ block: inout [String: Any]) -> Bool {
        func cut(_ text: String) -> String? {
            guard text.count > longLimit else { return nil }
            let head = text.prefix(2500)
            let tail = text.suffix(1000)
            return "\(head)\n\n[… AI Switchboard: \(text.count - 3500) caratteri rimossi …]\n\n\(tail)"
        }
        if let text = block["content"] as? String, let short = cut(text) {
            block["content"] = short
            return true
        }
        if var items = block["content"] as? [[String: Any]] {
            var changed = false
            for i in items.indices where items[i]["type"] as? String == "text" {
                if let text = items[i]["text"] as? String, let short = cut(text) {
                    items[i]["text"] = short
                    changed = true
                }
            }
            if changed { block["content"] = items }
            return changed
        }
        return false
    }

    /// Rough tokens a line adds to Claude's context: text at ~4 characters per token, images flat.
    private static func contextTokens(_ json: [String: Any]) -> Int {
        switch json["type"] as? String {
        case "attachment":
            let attachment = json["attachment"] as? [String: Any] ?? [:]
            if ephemeralAttachments.contains(attachment["type"] as? String ?? "") { return 0 }
            return jsonSize(attachment) / 4
        case "user", "assistant":
            guard let message = json["message"] as? [String: Any] else { return 0 }
            if let text = message["content"] as? String { return text.count / 4 }
            return (message["content"] as? [[String: Any]] ?? []).reduce(0) { $0 + blockTokens($1) }
        default:
            return 0
        }
    }

    private static func blockTokens(_ block: [String: Any]) -> Int {
        switch block["type"] as? String {
        case "image", "document": return imageTokens
        case "text": return (block["text"] as? String ?? "").count / 4
        case "thinking": return (block["thinking"] as? String ?? "").count / 4
        case "tool_use": return jsonSize(block["input"] ?? [:]) / 4
        case "tool_result":
            if let text = block["content"] as? String { return text.count / 4 }
            return (block["content"] as? [[String: Any]] ?? []).reduce(0) { $0 + blockTokens($1) }
        default: return 0
        }
    }

    private static func jsonSize(_ value: Any) -> Int {
        if let string = value as? String { return string.utf8.count + 2 }
        guard JSONSerialization.isValidJSONObject(value) else { return 0 }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]).count) ?? 0
    }

    // MARK: - Applying

    struct Outcome: Sendable {
        let before: Int
        let after: Int
        /// Tokens Claude no longer rereads, scaled to the context Claude Code measured.
        var tokensSaved = 0
        /// What slimming would still gain on the slimmed file, and the context left.
        var remaining: SlimEntry?
    }

    static func apply(_ source: Source, plan: Plan) throws -> Outcome {
        let fm = FileManager.default
        let url = source.chat.fileURL
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(source.chat.id).jsonl.slim")

        fm.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            var buffer = Data()
            for (i, line) in source.lines.enumerated() where !plan.dropped.contains(i) {
                if let json = plan.edited[i]?.value {
                    buffer.append(try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]))
                } else {
                    buffer.append(Data(line.raw.utf8))
                }
                buffer.append(0x0A)
                if buffer.count > 4_000_000 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.close()
            try verify(temp, source: source, plan: plan)
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temp)
            throw error
        }

        // The modification date must change or the original could be mistaken for current.
        let after = (try? fm.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0
        var trashed: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &trashed)
        do {
            try fm.moveItem(at: temp, to: url)
        } catch {
            if let trashed = trashed as URL? { try? fm.moveItem(at: trashed, to: url) }
            throw error
        }
        return Outcome(before: source.sizeBytes, after: after)
    }

    /// The slimmed file must hold the same conversation minus the removed messages, in the same
    /// order, with unique ids and every tool call paired with its result.
    private static func verify(_ url: URL, source: Source, plan: Plan) throws {
        let data = try Data(contentsOf: url)
        var lines: [Line] = []
        for raw in data.split(separator: 0x0A) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else {
                throw ChatOperationError.io("Verifica fallita: riga non valida")
            }
            lines.append(Line(raw: "", json: json))
        }

        var seen: Set<String> = []
        for line in lines where line.isMain {
            guard seen.insert(line.uuid!).inserted else { throw ChatOperationError.io("Verifica fallita: messaggio duplicato") }
        }

        let removed = Set(plan.dropped.compactMap { source.lines[$0].isMain ? source.lines[$0].uuid : nil })
        let index = mainIndex(lines)
        let effective = walk(lines, index: index, crossCompactions: false)
        guard effective == source.effectiveChain.filter({ !removed.contains($0) }) else {
            throw ChatOperationError.io("Verifica fallita: la conversazione ripresa da Claude non corrisponde")
        }
        if !plan.savings.keys.contains(.compacted) {
            let full = walk(lines, index: index, crossCompactions: true)
            guard full == source.fullChain.filter({ !removed.contains($0) }) else {
                throw ChatOperationError.io("Verifica fallita: la storia completa non corrisponde")
            }
        }

        var calls: Set<String> = []
        var results: Set<String> = []
        let effectiveSet = Set(effective)
        for line in lines where line.isMain && effectiveSet.contains(line.uuid!) {
            for block in line.content ?? [] {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String { calls.insert(id) }
                if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String { results.insert(id) }
            }
        }
        var originalCalls: Set<String> = []
        var originalResults: Set<String> = []
        for line in source.lines where line.isMain && source.effective.contains(line.uuid!) {
            for block in line.content ?? [] {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String { originalCalls.insert(id) }
                if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String { originalResults.insert(id) }
            }
        }
        guard calls == originalCalls, results == originalResults else {
            throw ChatOperationError.io("Verifica fallita: chiamate ai tool e risultati non corrispondono")
        }
    }
}
