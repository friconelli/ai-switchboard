import Foundation
import AppKit

struct PendingLaunch: Identifiable {
    let id = UUID()
    let command: String
    let directory: String
}

@MainActor
final class DeckStore: ObservableObject {
    @Published var accounts: [ClaudeAccount] = []
    @Published var chats: [ChatSession] = []
    @Published var sessionAccounts: [String: Set<String>] = [:]
    @Published var activeSessions: [ActiveSession] = []
    @Published var memoryFiles: [MemoryFile] = []
    @Published var config = SwitchboardConfig.load()
    @Published var areas: [WorkFolder] = []
    @Published var projects: [WorkFolder] = []

    @Published var isIndexing = false
    @Published var indexProgress: Double = 0
    @Published var contentMatches: Set<String>?
    @Published var isSearchingContent = false
    @Published var errorMessage: String?
    @Published var directLaunchEnabled = ShellHook.isInstalled
    @Published var pendingLaunch: PendingLaunch?
    @Published var usage: [String: ChatUsage] = [:]
    @Published var descriptions: [String: String] = [:]
    @Published var describingRemaining = 0
    @Published var isScanningUsage = false
    @Published var slimEntries: [String: SlimEntry] = SlimAdvisor.load()

    private let indexer = ChatIndexer()
    private let usageScanner = UsageScanner()
    private let descriptionCache = DescriptionCache()
    private var isDescribing = false
    private var isScanningSlim = false
    /// A reload asked for while another was running: run again when it ends, so the result is never stale.
    private var reloadChatsQueued = false
    private var reloadUsageQueued = false
    private var rescanSlimQueued = false
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
        Workspaces.ensureRoots(config)
        reloadFolders()
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
        guard !isIndexing else {
            reloadChatsQueued = true
            return
        }
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
                if self.reloadChatsQueued {
                    self.reloadChatsQueued = false
                    self.reloadChats()
                } else {
                    self.reloadUsage()
                }
            }
        }
    }

    func reloadUsage() {
        guard !isScanningUsage else {
            reloadUsageQueued = true
            return
        }
        isScanningUsage = true
        let scanner = usageScanner
        let chats = chats
        Task.detached(priority: .utility) {
            let result = scanner.scan(chats)
            await MainActor.run {
                self.usage = result
                self.isScanningUsage = false
                if self.reloadUsageQueued {
                    self.reloadUsageQueued = false
                    self.reloadUsage()
                } else {
                    self.refreshDescriptions()
                    self.refreshSlimEntries()
                }
            }
        }
    }

    // MARK: - Slimming advice

    /// What slimming would gain on `chat` as the file is now; nil until it has been worked out.
    func slimEntry(for chat: ChatSession) -> SlimEntry? {
        slimEntries[chat.id].flatMap { $0.matches(chat) ? $0 : nil }
    }

    /// Context Claude rereads on resume: reduced by slimming, otherwise as recorded by Claude Code.
    func contextTokens(for chat: ChatSession) -> Int {
        slimEntry(for: chat)?.context ?? usage[chat.id]?.lastContext ?? 0
    }

    func insights(for chat: ChatSession) -> [ModelAdvisor.Insight] {
        guard let usage = usage[chat.id] else { return [] }
        return ModelAdvisor.insights(for: chat, usage: usage, context: contextTokens(for: chat), slim: slimEntry(for: chat))
    }

    /// The lightbulb: something to do that really pays off.
    func hasAdvice(for chat: ChatSession) -> Bool {
        insights(for: chat).contains { $0.isMajor }
    }

    /// Works out the gain for chats that could have one, one at a time, publishing each result.
    func refreshSlimEntries() {
        guard !isScanningSlim else {
            rescanSlimQueued = true
            return
        }
        let active = activeSessionIDs
        let pending = chats.filter { chat in
            slimEntry(for: chat) == nil
                && !active.contains(chat.id)
                && SlimAdvisor.isCandidate(chat, measuredContext: usage[chat.id]?.lastContext ?? 0)
        }
        let live = Set(chats.map(\.id))
        if slimEntries.keys.contains(where: { !live.contains($0) }) {
            slimEntries = slimEntries.filter { live.contains($0.key) }
            SlimAdvisor.save(slimEntries)
        }
        guard !pending.isEmpty else { return }
        isScanningSlim = true
        let measured = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, usage[$0.id]?.lastContext ?? 0) })
        Task.detached(priority: .utility) {
            for chat in pending {
                let entry = SlimAdvisor.evaluate(chat, measured: measured[chat.id] ?? 0)
                await MainActor.run {
                    if let entry { self.slimEntries[chat.id] = entry }
                }
            }
            await MainActor.run {
                SlimAdvisor.save(self.slimEntries)
                self.isScanningSlim = false
                if self.rescanSlimQueued {
                    self.rescanSlimQueued = false
                    self.refreshSlimEntries()
                }
            }
        }
    }

    // MARK: - Descriptions

    var autoDescriptions: Bool {
        get { config.autoDescriptions ?? true }
        set {
            config.autoDescriptions = newValue
            config.save()
            if newValue { refreshDescriptions() }
        }
    }

    func description(for chat: ChatSession) -> String? {
        descriptions[chat.id]
    }

    /// Writes missing or outdated descriptions in the background, most recent chats first,
    /// five chats per request. `force` rewrites the given chats even if they have one.
    func refreshDescriptions(force: [ChatSession] = []) {
        descriptions = descriptionCache.entries.mapValues(\.text)
        guard !isDescribing, autoDescriptions || !force.isEmpty else { return }
        var queue = force + chats
            .filter { descriptionCache.needsDescription($0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        guard !queue.isEmpty else { return }
        isDescribing = true
        describingRemaining = queue.count
        let account = preferredAccount
        Task {
            while !queue.isEmpty {
                let batch = Array(queue.prefix(5))
                queue.removeFirst(batch.count)
                if let texts = try? await DescriptionWriter.describe(batch, account: account) {
                    descriptionCache.store(texts, chats: batch)
                    descriptions = descriptionCache.entries.mapValues(\.text)
                }
                describingRemaining = queue.count
            }
            isDescribing = false
        }
    }

    // MARK: - Models

    func recommendation(for chat: ChatSession) -> ModelAdvisor.Recommendation? {
        usage[chat.id].flatMap { ModelAdvisor.recommend($0, prompts: chat.promptCount) }
    }

    /// Most frequent recommendation among the chats started in `folder`, weighted by responses.
    func recommendedTier(forFolder folder: String) -> ModelTier? {
        var votes: [ModelTier: Int] = [:]
        for chat in chats where chat.workingDirectory == folder {
            guard let usage = usage[chat.id], let tier = ModelAdvisor.recommend(usage, prompts: chat.promptCount)?.tier else { continue }
            votes[tier, default: 0] += usage.responses
        }
        return votes.max { $0.value < $1.value }?.key
    }

    var useRecommendedModel: Bool {
        get { config.useRecommendedModel ?? false }
        set {
            config.useRecommendedModel = newValue
            config.save()
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

    /// `model` nil: the recommended one when that option is on, otherwise Claude Code's default.
    func resume(_ chat: ChatSession, with account: ClaudeAccount, model: ModelTier? = nil) {
        let tier = model ?? (useRecommendedModel ? recommendation(for: chat)?.tier : nil)
        handle(Launcher.resume(chat, account: account, model: tier?.alias))
    }

    func newChat(in directory: String, with account: ClaudeAccount) {
        let tier = useRecommendedModel ? recommendedTier(forFolder: directory) : nil
        handle(Launcher.newChat(in: directory, account: account, model: tier?.alias))
    }

    /// Creates a chat that opens with `summary` and starts it with `request` as first message.
    /// Without a summary it is a plain new chat in `folder`.
    func startComposed(
        title: String,
        folder: String,
        summary: String?,
        sources: [ChatSession],
        request: String,
        sendRequest: Bool,
        account: ClaudeAccount,
        model: ModelTier?
    ) -> ChatSession? {
        let prompt = sendRequest ? request : nil
        guard let summary else {
            handle(Launcher.newChat(in: folder, account: account, model: model?.alias, prompt: prompt))
            return nil
        }
        do {
            let chat = try ComposeEngine.create(title: title, folder: folder, summary: summary, sourceTitles: sources.map(\.displayTitle))
            if !account.isDefault { try? appendHistory(chat.id, cwd: folder, title: title, account: account) }
            handle(Launcher.resume(chat, account: account, model: model?.alias, prompt: prompt))
            reloadChats()
            return chat
        } catch {
            errorMessage = "Non sono riuscito a creare la chat.\n\n\(error.localizedDescription)"
            return nil
        }
    }

    func reloadAccounts() {
        let fresh = AccountScanner.accounts()
        if fresh.map(\.id) != accounts.map(\.id) || fresh.map(\.email) != accounts.map(\.email) {
            accounts = fresh
            sessionAccounts = AccountScanner.sessionAccounts(accounts)
        }
    }

    /// Opens Claude with that configuration folder, which asks to log in when needed.
    func login(configDir: URL) {
        handle(Launcher.run(AccountSetup.loginCommand(for: configDir), in: ClaudePaths.home.path))
    }

    func setDirectLaunch(_ enabled: Bool) {
        do {
            if enabled { try ShellHook.install() } else { try ShellHook.uninstall() }
        } catch {
            errorMessage = error.localizedDescription
        }
        directLaunchEnabled = ShellHook.isInstalled
    }

    private func handle(_ outcome: Launcher.Outcome) {
        if case .needsDirectLaunch(let command, let directory) = outcome {
            pendingLaunch = PendingLaunch(command: command, directory: directory)
        }
    }

    /// Enables the shell hook, then runs the launch that was waiting for it.
    func enableDirectLaunchAndRun(_ launch: PendingLaunch) {
        setDirectLaunch(true)
        guard directLaunchEnabled else { return }
        handle(Launcher.run(launch.command, in: launch.directory))
    }

    func rename(_ chat: ChatSession, to title: String) {
        perform { try ChatOperations.rename(chat, to: title) }
        // The list shows the new title at once; the re-index only confirms it.
        if let position = chats.firstIndex(where: { $0.id == chat.id }), errorMessage == nil {
            chats[position].title = title
            chats[position].isCustomTitle = true
        }
    }

    func trash(_ chats: [ChatSession]) {
        let active = activeSessionIDs
        if let busy = chats.first(where: { active.contains($0.id) }) {
            errorMessage = ChatOperationError.active(busy.displayTitle).localizedDescription
            return
        }
        var trashed: Set<String> = []
        perform {
            for chat in chats {
                try ChatOperations.trash(chat)
                trashed.insert(chat.id)
            }
        }
        self.chats.removeAll { trashed.contains($0.id) }
        usage = usage.filter { !trashed.contains($0.key) }
        slimEntries = slimEntries.filter { !trashed.contains($0.key) }
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

    /// Splits `source` into one new chat per topic; the original goes to the Trash only if every
    /// new chat was written and verified and `trashOriginal` is set. Returns the new chats.
    func split(_ source: SplitEngine.Source, topics: [SplitEngine.Topic], trashOriginal: Bool) -> [ChatSession] {
        let chat = source.chat
        if activeSessionIDs.contains(chat.id) {
            errorMessage = ChatOperationError.active(chat.displayTitle).localizedDescription
            return []
        }

        let results: [SplitEngine.Result]
        do {
            results = try SplitEngine.split(source, topics: topics, configDirs: accounts.map(\.configDir))
        } catch {
            errorMessage = "Divisione non riuscita, la chat originale non è stata toccata.\n\n\(error.localizedDescription)"
            return []
        }

        for account in accounts where !account.isDefault && (sessionAccounts[chat.id]?.contains(account.id) ?? false) {
            for result in results {
                try? appendHistory(result.sessionID, cwd: result.folder, title: result.title, account: account)
            }
        }

        if trashOriginal {
            do { try ChatOperations.trash(chat) } catch {
                errorMessage = "Divisione completata, ma non ho potuto spostare nel Cestino “\(chat.displayTitle)”."
            }
        }

        sessionAccounts = AccountScanner.sessionAccounts(accounts)
        reloadChats()
        return results.map {
            ChatSession(
                id: $0.sessionID,
                fileURL: $0.fileURL,
                projectDir: $0.projectDir,
                cwd: $0.folder,
                title: $0.title,
                isCustomTitle: true,
                modifiedAt: Date(),
                sizeBytes: 0
            )
        }
    }

    struct SlimResult {
        var slimmed = 0
        /// Chats with nothing worth removing, left untouched.
        var alreadySlim = 0
        var before = 0
        var after = 0
        var tokensSaved = 0
        var problems: [String] = []
    }

    /// Slims chats one at a time (each is read, rewritten, verified and swapped in place).
    /// A chat where the chosen categories would gain next to nothing is left alone.
    func slim(_ chats: [ChatSession], enabled: Set<SlimEngine.Category>, progress: @escaping (Int) -> Void) async -> SlimResult {
        var result = SlimResult()
        let active = activeSessionIDs
        for (index, chat) in chats.enumerated() {
            progress(index)
            if active.contains(chat.id) {
                result.problems.append("“\(chat.displayTitle)”: aperta in una sessione")
                continue
            }
            let measured = contextTokens(for: chat)
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { () -> SlimEngine.Outcome in
                    let source = try SlimEngine.analyze(chat)
                    let plan = SlimEngine.plan(source, enabled: enabled)
                    let scale = SlimAdvisor.factor(measured: measured, estimated: source.contextTokens)
                    let tokens = Int(Double(plan.tokensSaved) * scale)
                    guard tokens >= SlimAdvisor.sheetMinTokens || plan.bytesSaved >= SlimAdvisor.sheetMinBytes else {
                        return SlimEngine.Outcome(before: Int(source.sizeBytes), after: Int(source.sizeBytes))
                    }
                    var outcome = try SlimEngine.apply(source, plan: plan)
                    outcome.tokensSaved = tokens
                    let left = max(0, (measured > 0 ? measured : source.contextTokens) - tokens)
                    outcome.remaining = SlimAdvisor.evaluate(chat, measured: left)
                    return outcome
                }.value
                if outcome.before == outcome.after, outcome.remaining == nil {
                    result.alreadySlim += 1
                    continue
                }
                result.slimmed += 1
                result.before += outcome.before
                result.after += outcome.after
                result.tokensSaved += outcome.tokensSaved
                if let remaining = outcome.remaining {
                    slimEntries[chat.id] = remaining
                    // Show the new size straight away; the re-index below confirms it.
                    if let position = self.chats.firstIndex(where: { $0.id == chat.id }) {
                        self.chats[position].sizeBytes = remaining.size
                        self.chats[position].modifiedAt = remaining.modified
                    }
                }
            } catch {
                result.problems.append("“\(chat.displayTitle)”: \(error.localizedDescription)")
            }
        }
        SlimAdvisor.save(slimEntries)
        reloadChats()
        return result
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

    // MARK: - Contexts and folders

    func reloadFolders() {
        areas = Workspaces.areas(config)
        projects = Workspaces.projects(config)
    }

    func context(for chat: ChatSession) -> String? {
        config.context(for: chat)
    }

    func chats(in folder: WorkFolder) -> [ChatSession] {
        chats.filter { $0.workingDirectory.isInside(folder.path) }
    }

    /// `nil` resets the chat to its folder's context.
    func setContext(_ context: String?, for chats: [ChatSession]) {
        for chat in chats { config.chatContexts[chat.id] = context }
        config.save()
    }

    func setContext(_ context: String?, forFolder path: String) {
        config.folderContexts[path] = context
        config.save()
        reloadFolders()
    }

    func createArea(named name: String, context: String) -> String? {
        do {
            let path = try Workspaces.createArea(named: name, context: context, config: config)
            reloadFolders()
            return path
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Moves chats to `folder`; returns how many were moved.
    @discardableResult
    func move(_ chats: [ChatSession], to folder: String) -> Int {
        let active = activeSessionIDs
        var moved = 0
        var problems: [String] = []
        for chat in chats {
            if active.contains(chat.id) {
                problems.append("“\(chat.displayTitle)” è aperta in una sessione")
                continue
            }
            do {
                _ = try ChatMover.move(chat, to: folder)
                moved += 1
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty {
            errorMessage = "Spostate \(moved) chat su \(chats.count).\n\n" + problems.joined(separator: "\n")
        }
        reloadChats()
        return moved
    }

    func moveMemory(_ file: MemoryFile, toFolder folder: String) {
        do {
            try MemoryMover.move(file, toFolder: folder)
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadMemory()
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
