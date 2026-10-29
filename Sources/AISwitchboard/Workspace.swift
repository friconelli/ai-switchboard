import Foundation

/// User settings: where AI chats live and how chats are split into contexts.
struct SwitchboardConfig: Codable {
    var chatRoot: String = ClaudePaths.home.appendingPathComponent("Chat AI").path
    var projectsRoot: String = ClaudePaths.home.appendingPathComponent("projects").path
    var contexts: [String] = ["Personale", "Studiogusto"]
    /// Context for code projects in `projectsRoot` that have no explicit assignment.
    var defaultProjectContext: String? = "Studiogusto"
    /// Explicit context per working directory (code projects or any other folder).
    var folderContexts: [String: String] = [:]
    /// Explicit context per chat, overriding its folder.
    var chatContexts: [String: String] = [:]
    /// Start and resume chats with the model suggested by their history (optional for old configs).
    var useRecommendedModel: Bool?
    /// Let Claude (Haiku) write a short description of every chat; on unless switched off.
    var autoDescriptions: Bool?

    private static var url: URL { ClaudePaths.appSupport.appendingPathComponent("config.json") }

    static func load() -> SwitchboardConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SwitchboardConfig.self, from: data) else { return SwitchboardConfig() }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }

    // MARK: - Context resolution

    /// Context of a working directory: its area in the chat root, an explicit assignment,
    /// or the default for code projects. `nil` means "da assegnare".
    func context(forFolder path: String) -> String? {
        for context in contexts where path.isInside(contextRoot(context)) {
            return context
        }
        if let explicit = folderContexts[path] { return explicit }
        if let project = projectFolder(containing: path) {
            return folderContexts[project] ?? defaultProjectContext
        }
        return nil
    }

    func context(for chat: ChatSession) -> String? {
        chatContexts[chat.id] ?? context(forFolder: chat.workingDirectory)
    }

    func contextRoot(_ context: String) -> String {
        (chatRoot as NSString).appendingPathComponent(context)
    }

    /// `~/projects/<repo>` for any path inside a repo; nil for the projects root itself.
    func projectFolder(containing path: String) -> String? {
        guard path.isInside(projectsRoot), path != projectsRoot else { return nil }
        let relative = path.dropFirst(projectsRoot.count + 1)
        guard let name = relative.split(separator: "/").first else { return nil }
        return (projectsRoot as NSString).appendingPathComponent(String(name))
    }
}

extension String {
    func isInside(_ folder: String) -> Bool {
        self == folder || hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

/// A folder chats can be started from: an area in the chat root or a code project.
struct WorkFolder: Identifiable, Hashable {
    enum Kind { case area, project }

    var id: String { path }
    let path: String
    let kind: Kind
    let context: String?

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum Workspaces {
    /// Claude Code stores a folder's chats in `~/.claude/projects/<encoded path>`,
    /// where every character that is not a letter or digit becomes `-`.
    static func encodedName(for path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
    }

    static func ensureRoots(_ config: SwitchboardConfig) {
        for context in config.contexts {
            try? FileManager.default.createDirectory(atPath: config.contextRoot(context), withIntermediateDirectories: true)
        }
    }

    static func areas(_ config: SwitchboardConfig) -> [WorkFolder] {
        config.contexts.flatMap { context -> [WorkFolder] in
            subfolders(of: config.contextRoot(context)).map { WorkFolder(path: $0, kind: .area, context: context) }
        }
    }

    static func projects(_ config: SwitchboardConfig) -> [WorkFolder] {
        subfolders(of: config.projectsRoot).map {
            WorkFolder(path: $0, kind: .project, context: config.context(forFolder: $0))
        }
    }

    private static func subfolders(of path: String) -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .map { (path as NSString).appendingPathComponent($0) }
            .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Creates `<chat root>/<context>/<name>` with a starter CLAUDE.md and resource folders.
    static func createArea(named name: String, context: String, config: SwitchboardConfig) throws -> String {
        let fm = FileManager.default
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty else { throw ChatOperationError.io("Nome vuoto") }
        let path = (config.contextRoot(context) as NSString).appendingPathComponent(trimmed)
        guard !fm.fileExists(atPath: path) else { throw ChatOperationError.io("Esiste già un'area “\(trimmed)” in \(context)") }

        try fm.createDirectory(atPath: (path as NSString).appendingPathComponent("risorse"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (path as NSString).appendingPathComponent("output"), withIntermediateDirectories: true)
        let claudeMD = """
        # \(trimmed)

        Contesto: \(context)

        ## Di cosa si occupa quest'area

        (descrivi qui l'attività, i clienti o i progetti coinvolti)

        ## Cartelle

        - `risorse/` — materiali di partenza (brief, PDF, immagini). File pesanti che stanno altrove: collegali con un alias o un symlink invece di copiarli.
        - `output/` — tutto quello che produce Claude.

        ## Regole

        (preferenze, cose da evitare, accessi)
        """
        try claudeMD.write(toFile: (path as NSString).appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        return path
    }
}
