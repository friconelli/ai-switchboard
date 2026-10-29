import Foundation
import AppKit

@MainActor
final class DeckStore: ObservableObject {
    @Published var accounts: [ClaudeAccount] = []
    @Published var chats: [ChatSession] = []
    @Published var sessionAccounts: [String: Set<String>] = [:]
    @Published var activeSessions: [ActiveSession] = []
    @Published var memoryFiles: [MemoryFile] = []

    @Published var isIndexing = false
    @Published var indexProgress: Double = 0
    @Published var contentMatches: Set<String>?
    @Published var isSearchingContent = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    private let indexer = ChatIndexer()
    private var timer: Timer?
    private var searchTask: Process?

    var activeSessionIDs: Set<String> { Set(activeSessions.map(\.sessionId)) }

    func start() {
        reloadAll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActiveSessions() }
        }
    }

    func reloadAll() {
        accounts = AccountScanner.accounts()
        sessionAccounts = AccountScanner.sessionAccounts(accounts)
        refreshActiveSessions()
        reloadChats()
        reloadMemory()
    }

    func refreshActiveSessions() {
        let sessions = AccountScanner.activeSessions(accounts)
        if sessions != activeSessions { activeSessions = sessions }
    }

    func reloadChats() {
        guard !isIndexing else { return }
        isIndexing = true
        let indexer = indexer
        Task.detached(priority: .userInitiated) {
            let result = indexer.indexAll { done, total in
                guard total > 0, done % 10 == 0 else { return }
                Task { @MainActor in self.indexProgress = Double(done) / Double(total) }
            }
            await MainActor.run {
                self.chats = result
                self.isIndexing = false
                self.indexProgress = 1
            }
        }
    }

    // MARK: - Lookups

    func account(id: String) -> ClaudeAccount? {
        accounts.first { $0.id == id }
    }

    func accounts(for chat: ChatSession) -> [ClaudeAccount] {
        let ids = sessionAccounts[chat.id] ?? []
        return accounts.filter { ids.contains($0.id) && !$0.isDefault }
    }

    func chat(id: String) -> ChatSession? {
        chats.first { $0.id == id }
    }

    /// Account to propose for resuming: the one that last used Claude (most likely to have credits).
    var preferredAccount: ClaudeAccount? {
        accounts.filter { !$0.isDefault }.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
            ?? accounts.first
    }

    // MARK: - Content search

    func searchContent(_ query: String) {
        searchTask?.terminate()
        guard query.count >= 2 else {
            contentMatches = nil
            isSearchingContent = false
            return
        }
        isSearchingContent = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-rliF", "--include=*.jsonl", "--", query, ClaudePaths.projects.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        searchTask = process

        Task.detached {
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let ids = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)).deletingPathExtension().lastPathComponent }
            await MainActor.run {
                guard self.searchTask === process else { return }
                self.contentMatches = Set(ids)
                self.isSearchingContent = false
            }
        }
    }

    // MARK: - Chat actions

    func resume(_ chat: ChatSession, with account: ClaudeAccount) {
        handle(Launcher.resume(chat, account: account))
    }

    func newChat(in directory: String, with account: ClaudeAccount) {
        handle(Launcher.newChat(in: directory, account: account))
    }

    private func handle(_ outcome: Launcher.Outcome) {
        if case .copiedToClipboard(let command) = outcome {
            noticeMessage = "Ho aperto una scheda Warp e copiato il comando negli appunti: incollalo con ⌘V e premi Invio.\n\n\(command)\n\nPer farlo in automatico, abilita AI Switchboard in Impostazioni di Sistema → Privacy e sicurezza → Accessibilità."
        }
    }

    func rename(_ chat: ChatSession, to title: String) {
        perform { try ChatOperations.rename(chat, to: title) }
    }

    func trash(_ chats: [ChatSession]) {
        let active = activeSessionIDs
        if let busy = chats.first(where: { active.contains($0.id) }) {
            errorMessage = ChatOperationError.active(busy.displayTitle).localizedDescription
            return
        }
        perform {
            for chat in chats { try ChatOperations.trash(chat) }
        }
    }

    /// Merges `ordered` (in the given order) into a new chat saved next to `target`, then moves
    /// the originals to the Trash. Returns the new chat, or nil on failure (originals untouched).
    func merge(_ ordered: [ChatSession], title: String, target: ChatSession) -> ChatSession? {
        let active = activeSessionIDs
        if let busy = ordered.first(where: { active.contains($0.id) }) {
            errorMessage = ChatOperationError.active(busy.displayTitle).localizedDescription
            return nil
        }

        let result: MergeEngine.Result
        do {
            result = try MergeEngine.merge(
                ordered,
                title: title,
                targetFolder: target.fileURL.deletingLastPathComponent(),
                configDirs: accounts.map(\.configDir)
            )
        } catch {
            errorMessage = "Unione non riuscita, le chat originali non sono state toccate.\n\n\(error.localizedDescription)"
            return nil
        }

        // Make the merged chat show up in /resume history of every account that used a source.
        for account in accounts where !account.isDefault {
            let used = ordered.contains { sessionAccounts[$0.id]?.contains(account.id) ?? false }
            if used { try? appendHistory(result.sessionID, cwd: target.workingDirectory, title: title, account: account) }
        }

        var failed: [String] = []
        for chat in ordered {
            do { try ChatOperations.trash(chat) } catch { failed.append(chat.displayTitle) }
        }
        if !failed.isEmpty {
            errorMessage = "Unione completata, ma non ho potuto spostare nel Cestino: \(failed.joined(separator: ", "))."
        }

        sessionAccounts = AccountScanner.sessionAccounts(accounts)
        reloadChats()
        return ChatSession(
            id: result.sessionID,
            fileURL: result.fileURL,
            projectDir: target.projectDir,
            cwd: target.cwd,
            title: title,
            isCustomTitle: true,
            modifiedAt: Date(),
            sizeBytes: 0
        )
    }

    func killSession(_ session: ActiveSession) {
        kill(session.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshActiveSessions() }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
        sessionAccounts = AccountScanner.sessionAccounts(accounts)
        reloadChats()
    }

    /// Adds an entry to the account's prompt history so the merged chat shows up in `/resume`.
    private func appendHistory(_ sessionID: String, cwd: String, title: String, account: ClaudeAccount) throws {
        let url = account.configDir.appendingPathComponent("history.jsonl")
        let record: [String: Any] = [
            "display": "[AI Switchboard] \(title)",
            "pastedContents": [String: Any](),
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "project": cwd,
            "sessionId": sessionID,
        ]
        var line = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    // MARK: - Memory

    func reloadMemory() {
        let fm = FileManager.default
        var files: [MemoryFile] = []
        let projects = (try? fm.contentsOfDirectory(at: ClaudePaths.projects, includingPropertiesForKeys: nil)) ?? []
        for project in projects {
            let dir = project.appendingPathComponent("memory")
            let entries = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []
            for file in entries where file.pathExtension == "md" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append(MemoryFile(
                    url: file,
                    projectDir: project.lastPathComponent,
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    sizeBytes: Int64(values?.fileSize ?? 0)
                ))
            }
        }
        memoryFiles = files.sorted {
            ($0.projectDir, $0.isIndex ? 0 : 1, $0.url.lastPathComponent) < ($1.projectDir, $1.isIndex ? 0 : 1, $1.url.lastPathComponent)
        }
    }

    func trashMemory(_ file: MemoryFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadMemory()
    }
}

/// Readable project name from Claude's encoded folder name (`-Users-me-projects-foo` → `foo`).
func projectLabel(_ projectDir: String) -> String {
    let home = "-" + ClaudePaths.home.path.dropFirst().replacingOccurrences(of: "/", with: "-")
    if projectDir == home { return "~" }
    if projectDir.hasPrefix(home + "-projects-") { return String(projectDir.dropFirst(home.count + "-projects-".count)) }
    if projectDir.hasPrefix(home + "-") { return "~/" + projectDir.dropFirst(home.count + 1) }
    if projectDir.hasPrefix("-Applications-MAMP-htdocs-") {
        return "MAMP/" + projectDir.dropFirst("-Applications-MAMP-htdocs-".count)
    }
    return projectDir.hasPrefix("-") ? "/" + projectDir.dropFirst() : projectDir
}
