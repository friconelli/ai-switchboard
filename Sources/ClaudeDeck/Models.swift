import Foundation

/// One Claude Code configuration directory (= one logged-in account).
struct ClaudeAccount: Identifiable, Hashable {
    let id: String
    let name: String
    let configDir: URL
    let isDefault: Bool
    var email: String?
    var organization: String?
    var plan: String?
    var model: String?
    var pluginCount: Int = 0
    var lastActivity: Date?
    var promptsToday: Int = 0
    var sharesHistory: Bool = false

    /// Shell prefix that selects this account.
    var commandPrefix: String {
        isDefault ? "claude" : "CLAUDE_CONFIG_DIR='\(configDir.path)' claude"
    }

    var planLabel: String? {
        guard let plan else { return nil }
        switch plan {
        case "claude_pro": return "Pro"
        case "claude_max": return "Max"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return plan.replacingOccurrences(of: "claude_", with: "").capitalized
        }
    }
}

/// A chat transcript stored as `<projects>/<project>/<sessionId>.jsonl`.
struct ChatSession: Identifiable, Hashable, Codable {
    let id: String
    let fileURL: URL
    let projectDir: String
    var cwd: String?
    var title: String?
    var isCustomTitle = false
    var firstPrompt: String?
    var promptCount = 0
    var startedAt: Date?
    var modifiedAt: Date
    var sizeBytes: Int64

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let firstPrompt, !firstPrompt.isEmpty { return firstPrompt }
        return "Chat senza titolo"
    }

    var projectName: String {
        if let cwd { return URL(fileURLWithPath: cwd).lastPathComponent }
        return projectDir
    }

    var workingDirectory: String {
        cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}

/// A running `claude` process, from `<configDir>/sessions/<pid>.json`.
struct ActiveSession: Identifiable, Hashable {
    var id: Int32 { pid }
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String?
    let kind: String?
    let startedAt: Date?
    let updatedAt: Date?
    let accountID: String
    let accountName: String
}

/// A message shown in the transcript preview.
struct TranscriptMessage: Identifiable {
    enum Kind {
        case user
        case assistant
        case command
        case tools([String])
    }

    let id: Int
    let kind: Kind
    let text: String
    let timestamp: Date?
}

struct MemoryFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let projectDir: String
    let modifiedAt: Date
    let sizeBytes: Int64

    var isIndex: Bool { url.lastPathComponent == "MEMORY.md" }
}

let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
}()

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func relative(_ date: Date?) -> String {
    guard let date else { return "—" }
    return relativeFormatter.localizedString(for: date, relativeTo: Date())
}

enum ClaudePaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Shared transcript store (both accounts symlink their `projects` here).
    static var projects: URL {
        home.appendingPathComponent(".claude/projects").resolvingSymlinksInPath()
    }

    static var appSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeDeck")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
