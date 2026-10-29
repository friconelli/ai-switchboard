import SwiftUI
import AppKit

struct ChatsView: View {
    @ObservedObject var store: DeckStore
    @Binding var focusedChatID: String?

    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var searchContent = false
    @State private var projectFilter: String?
    @State private var accountFilter: String?

    @State private var renameTarget: ChatSession?
    @State private var mergeTargets: [ChatSession] = []
    @State private var trashTargets: [ChatSession] = []

    private var projects: [(dir: String, count: Int)] {
        Dictionary(grouping: store.chats, by: \.projectDir)
            .map { ($0.key, $0.value.count) }
            .sorted { projectLabel($0.dir).localizedCaseInsensitiveCompare(projectLabel($1.dir)) == .orderedAscending }
    }

    private var filtered: [ChatSession] {
        store.chats.filter { chat in
            if let projectFilter, chat.projectDir != projectFilter { return false }
            if let accountFilter, !(store.sessionAccounts[chat.id]?.contains(accountFilter) ?? false) { return false }
            guard !query.isEmpty else { return true }
            if searchContent { return store.contentMatches?.contains(chat.id) ?? true }
            return chat.displayTitle.localizedCaseInsensitiveContains(query)
                || (chat.firstPrompt?.localizedCaseInsensitiveContains(query) ?? false)
                || chat.projectName.localizedCaseInsensitiveContains(query)
                || chat.id.hasPrefix(query)
        }
    }

    private var selectedChats: [ChatSession] {
        store.chats.filter { selection.contains($0.id) }
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 380, idealWidth: 460, maxWidth: 620)
            detailPane
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .navigationTitle("Chat")
        .toolbar { toolbar }
        .onChange(of: focusedChatID) { _, id in
            guard let id else { return }
            selection = [id]
            projectFilter = nil
            accountFilter = nil
            query = ""
            focusedChatID = nil
        }
        .onChange(of: query) { _, value in
            if searchContent { store.searchContent(value) }
        }
        .onChange(of: searchContent) { _, enabled in
            store.searchContent(enabled ? query : "")
        }
        .sheet(item: $renameTarget) { chat in
            RenameSheet(chat: chat) { title in
                store.rename(chat, to: title)
            }
        }
        .sheet(isPresented: Binding(get: { !mergeTargets.isEmpty }, set: { if !$0 { mergeTargets = [] } })) {
            MergeSheet(store: store, chats: mergeTargets) { newID in
                if let newID { selection = [newID] }
            }
        }
        .alert(
            "Spostare \(trashTargets.count) chat nel Cestino?",
            isPresented: Binding(get: { !trashTargets.isEmpty }, set: { if !$0 { trashTargets = [] } })
        ) {
            Button("Sposta nel Cestino", role: .destructive) {
                store.trash(trashTargets)
                selection.subtract(trashTargets.map(\.id))
                trashTargets = []
            }
            Button("Annulla", role: .cancel) { trashTargets = [] }
        } message: {
            Text("Le potrai recuperare dal Cestino finché non lo svuoti. Spariranno da /resume per tutti gli account.")
        }
    }

    // MARK: - List

    private var listPane: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filtered.isEmpty && !store.isIndexing {
                EmptyStateView(
                    symbol: "bubble.left.and.bubble.right",
                    title: query.isEmpty ? "Nessuna chat" : "Nessun risultato",
                    message: query.isEmpty ? nil : "Prova a cercare anche nel contenuto delle conversazioni."
                )
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { chat in
                        ChatRow(
                            chat: chat,
                            accounts: store.accounts(for: chat),
                            isActive: store.activeSessionIDs.contains(chat.id)
                        )
                        .tag(chat.id)
                        .contextMenu { contextMenu(for: chat) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .overlay(alignment: .bottom) {
            if !selection.isEmpty { actionBar }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchContent ? "Cerca nel contenuto delle chat" : "Cerca titolo, progetto o ID", text: $query)
                    .textFieldStyle(.plain)
                if store.isSearchingContent {
                    ProgressView().controlSize(.small)
                }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Toggle(isOn: $searchContent) {
                    Label("Nel contenuto", systemImage: "text.magnifyingglass")
                }
                .toggleStyle(.button)
                .controlSize(.small)

                Menu {
                    Button("Tutti i progetti") { projectFilter = nil }
                    Divider()
                    ForEach(projects, id: \.dir) { project in
                        Button("\(projectLabel(project.dir)) (\(project.count))") { projectFilter = project.dir }
                    }
                } label: {
                    Label(projectFilter.map(projectLabel) ?? "Tutti i progetti", systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()

                Menu {
                    Button("Tutti gli account") { accountFilter = nil }
                    Divider()
                    ForEach(store.accounts.filter { !$0.isDefault }) { account in
                        Button(account.name) { accountFilter = account.id }
                    }
                } label: {
                    Label(accountFilter.flatMap { store.account(id: $0)?.name } ?? "Tutti gli account", systemImage: "person.crop.circle")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()

                Spacer()
                Text("\(filtered.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var actionBar: some View {
        ActionBar {
            Text(selection.count == 1 ? "1 chat" : "\(selection.count) chat")
                .font(.callout.weight(.semibold))

            Spacer()

            if selectedChats.count == 1, let chat = selectedChats.first {
                resumeMenu(for: chat)
                Button {
                    renameTarget = chat
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Rinomina")
                .secondaryButton()
            }

            if selectedChats.count >= 2 {
                Button {
                    mergeTargets = selectedChats
                } label: {
                    Label("Unisci", systemImage: "arrow.triangle.merge")
                }
                .prominentButton()
                .tint(Theme.coral)
            }

            Button(role: .destructive) {
                trashTargets = selectedChats
            } label: {
                Image(systemName: "trash")
            }
            .help("Sposta nel Cestino")
            .secondaryButton()
            .foregroundStyle(.red)
        }
        .padding(.horizontal, -12)
    }

    private func resumeMenu(for chat: ChatSession) -> some View {
        Menu {
            ForEach(store.accounts) { account in
                Button {
                    store.resume(chat, with: account)
                } label: {
                    Text("\(account.name)\(account.email.map { " — \($0)" } ?? "")")
                }
            }
        } label: {
            Label("Riprendi", systemImage: "play.fill")
        } primaryAction: {
            if let account = store.preferredAccount { store.resume(chat, with: account) }
        }
        .menuStyle(.button)
        .prominentButton()
        .tint(Theme.coral)
        .fixedSize()
        .help("Riprendi in \(Launcher.terminalName) con \(store.preferredAccount?.name ?? "l'account predefinito") (freccia per scegliere)")
    }

    @ViewBuilder
    private func contextMenu(for chat: ChatSession) -> some View {
        let targets = selection.contains(chat.id) ? selectedChats : [chat]
        if targets.count == 1 {
            Menu("Riprendi in \(Launcher.terminalName) con…") {
                ForEach(store.accounts) { account in
                    Button(account.name) { store.resume(chat, with: account) }
                }
            }
            Button("Rinomina…") { renameTarget = chat }
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([chat.fileURL]) }
            Button("Copia ID sessione") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.id, forType: .string)
            }
        } else {
            Button("Unisci \(targets.count) chat…") { mergeTargets = targets }
        }
        Divider()
        Button("Sposta nel Cestino", role: .destructive) { trashTargets = targets }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if selectedChats.count == 1, let chat = selectedChats.first {
            TranscriptView(store: store, chat: chat)
                .id(chat.id)
        } else if selectedChats.count > 1 {
            MultiSelectionView(chats: selectedChats) {
                mergeTargets = selectedChats
            }
        } else {
            EmptyStateView(
                symbol: "text.bubble",
                title: "Seleziona una chat",
                message: "⌘-clic per selezionarne più di una e unirle."
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                ForEach(store.accounts) { account in
                    Button(account.name) { newChat(with: account) }
                }
            } label: {
                Label("Nuova chat", systemImage: "plus.bubble")
            }
            .help("Nuova chat in \(Launcher.terminalName)")
        }
        ToolbarItem {
            Button {
                store.reloadAll()
            } label: {
                Label("Aggiorna", systemImage: "arrow.clockwise")
            }
            .help("Aggiorna")
        }
    }

    private func newChat(with account: ClaudeAccount) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Avvia Claude qui"
        panel.directoryURL = ClaudePaths.home.appendingPathComponent("projects")
        if panel.runModal() == .OK, let url = panel.url {
            Launcher.newChat(in: url.path, account: account)
        }
    }
}

// MARK: - Row

private struct ChatRow: View {
    let chat: ChatSession
    let accounts: [ClaudeAccount]
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if isActive {
                    StatusDot(busy: false)
                        .help("Aperta in una sessione in corso")
                }
                Text(chat.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(relative(chat.modifiedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let prompt = chat.firstPrompt, chat.title != nil {
                Text(prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Label(chat.projectName, systemImage: "folder.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(Theme.coral)
                    .lineLimit(1)
                ForEach(accounts) { account in
                    AccountBadge(account: account, compact: true)
                }
                Spacer()
                Text("\(chat.promptCount) msg · \(formatBytes(chat.sizeBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Multi selection

private struct MultiSelectionView: View {
    let chats: [ChatSession]
    let onMerge: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    symbol: "square.stack.fill",
                    tint: Theme.coral,
                    title: "\(chats.count) chat selezionate",
                    subtitle: "Puoi unirle in un'unica conversazione da riprendere con Claude: i messaggi vengono messi in ordine cronologico in una nuova chat, le originali restano intatte."
                ) {
                    Button(action: onMerge) {
                        Label("Unisci", systemImage: "arrow.triangle.merge")
                    }
                    .prominentButton()
                    .tint(Theme.coral)
                    .controlSize(.large)
                }
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(chats.sorted { ($0.startedAt ?? $0.modifiedAt) < ($1.startedAt ?? $1.modifiedAt) }) { chat in
                            HStack {
                                Text(chat.displayTitle).lineLimit(1)
                                Spacer()
                                Text(chat.projectName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(formatBytes(chat.sizeBytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .padding(10)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Sheets

private struct RenameSheet: View {
    let chat: ChatSession
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rinomina chat")
                .font(.title3.bold())
            TextField("Titolo", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Il nuovo titolo compare anche in /resume di Claude Code, per tutti gli account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rinomina", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { title = chat.title ?? "" }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

private struct MergeSheet: View {
    @ObservedObject var store: DeckStore
    let chats: [ChatSession]
    let onDone: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var openAfter = true
    @State private var accountID: String?

    private var ordered: [ChatSession] {
        chats.sorted { ($0.startedAt ?? $0.modifiedAt) < ($1.startedAt ?? $1.modifiedAt) }
    }

    private var totalSize: Int64 { chats.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.triangle.merge", tint: Theme.coral, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unisci \(chats.count) chat")
                        .font(.title3.bold())
                    Text("Verrà creata una nuova chat; le originali restano dove sono.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ordine (dalla più vecchia)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, chat in
                    HStack {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(chat.displayTitle).lineLimit(1)
                        Spacer()
                        Text(chat.projectName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            TextField("Titolo della nuova chat", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                Toggle("Apri subito in \(Launcher.terminalName) con", isOn: $openAfter)
                Picker("", selection: $accountID) {
                    ForEach(store.accounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!openAfter)
            }

            if Set(chats.map(\.projectDir)).count > 1 {
                Label("Le chat sono di progetti diversi: la nuova verrà salvata in “\(ordered[0].projectName)”.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if totalSize > 20_000_000 {
                Label("Totale \(formatBytes(totalSize)): alla ripresa Claude Code probabilmente compatterà il contesto.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unisci") {
                    let newID = store.merge(chats, title: title)
                    if openAfter, let newID, let account = accountID.flatMap(store.account(id:)) {
                        let merged = ChatSession(
                            id: newID,
                            fileURL: ordered[0].fileURL.deletingLastPathComponent().appendingPathComponent("\(newID).jsonl"),
                            projectDir: ordered[0].projectDir,
                            cwd: ordered[0].cwd,
                            title: title,
                            modifiedAt: Date(),
                            sizeBytes: 0
                        )
                        store.resume(merged, with: account)
                    }
                    onDone(newID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            title = "Unione: " + ordered.map { String($0.displayTitle.prefix(30)) }.joined(separator: " + ")
            accountID = store.preferredAccount?.id
        }
    }
}
