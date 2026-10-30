import SwiftUI
import AppKit

struct ChatsView: View {
    @ObservedObject var store: DeckStore
    let scope: ChatScope
    @Binding var focusedChatID: String?

    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var searchContent = false
    @State private var projectFilter: String?
    @State private var accountFilter: String?

    @State private var renameTarget: ChatSession?
    @State private var mergeTargets: [ChatSession] = []
    @State private var trashTargets: [ChatSession] = []
    @State private var moveTargets: [ChatSession] = []
    @State private var splitTarget: ChatSession?
    @State private var slimTargets: [ChatSession] = []

    private var projects: [(dir: String, count: Int)] {
        Dictionary(grouping: store.chats, by: \.projectDir)
            .map { ($0.key, $0.value.count) }
            .sorted { projectLabel($0.dir).localizedCaseInsensitiveCompare(projectLabel($1.dir)) == .orderedAscending }
    }

    private var filtered: [ChatSession] {
        store.chats.filter { chat in
            switch scope {
            case .all: break
            case .context(let context): if store.context(for: chat) != context { return false }
            case .unassigned: if store.context(for: chat) != nil { return false }
            }
            if let projectFilter, chat.projectDir != projectFilter { return false }
            if let accountFilter, !(store.sessionAccounts[chat.id]?.contains(accountFilter) ?? false) { return false }
            guard !query.isEmpty else { return true }
            if searchContent { return store.contentMatches?.contains(chat.id) ?? true }
            return chat.displayTitle.localizedCaseInsensitiveContains(query)
                || (chat.preview?.localizedCaseInsensitiveContains(query) ?? false)
                || (store.description(for: chat)?.localizedCaseInsensitiveContains(query) ?? false)
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
        .navigationTitle(scopeTitle)
        .toolbar { toolbar }
        .onChange(of: focusedChatID) { _, id in
            guard let id else { return }
            selection = [id]
            // Screenshots/tests: `-debugOpenSlim YES` opens the slim sheet for the focused chat.
            if UserDefaults.standard.bool(forKey: "debugOpenSlim"), let chat = store.chats.first(where: { $0.id == id }) {
                slimTargets = [chat]
            }
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
        .sheet(isPresented: Binding(get: { !moveTargets.isEmpty }, set: { if !$0 { moveTargets = [] } })) {
            FolderPickerSheet(
                store: store,
                title: moveTargets.count == 1 ? "Sposta “\(moveTargets[0].displayTitle)”" : "Sposta \(moveTargets.count) chat",
                message: "La chat verrà registrata nella nuova cartella: da lì la ritrovi con /resume e Claude lavora in quella cartella.",
                excluding: Set(moveTargets.map(\.workingDirectory))
            ) { folder in
                let targets = moveTargets
                selection.subtract(targets.map(\.id))
                store.move(targets, to: folder)
            }
        }
        .sheet(item: $renameTarget) { chat in
            RenameSheet(chat: chat) { title in
                store.rename(chat, to: title)
            }
        }
        .sheet(isPresented: Binding(get: { !slimTargets.isEmpty }, set: { if !$0 { slimTargets = [] } })) {
            SlimSheet(store: store, chats: slimTargets)
        }
        .sheet(item: $splitTarget) { chat in
            SplitSheet(store: store, chat: chat) { created in
                selection = Set(created.map(\.id))
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
                            context: store.context(for: chat),
                            showContext: scope == .all,
                            isActive: store.activeSessionIDs.contains(chat.id),
                            hasAdvice: store.hasAdvice(for: chat),
                            description: store.description(for: chat)
                        )
                        .tag(chat.id)
                        .contextMenu { contextMenu(for: chat) }
                    }
                }
                .listStyle(.inset)
            }
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

    private var actions: ChatActions {
        ChatActions(
            rename: { renameTarget = $0 },
            split: { splitTarget = $0 },
            slim: { slimTargets = $0 },
            move: { moveTargets = $0 },
            merge: { mergeTargets = $0 },
            trash: { trashTargets = $0 }
        )
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
            Button("Dividi in argomenti…") { splitTarget = chat }
            Button("Rigenera descrizione") { store.refreshDescriptions(force: [chat]) }
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([chat.fileURL]) }
            Button("Copia ID sessione") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.id, forType: .string)
            }
        } else {
            Button("Unisci \(targets.count) chat…") { mergeTargets = targets }
        }
        Button(targets.count == 1 ? "Snellisci…" : "Snellisci \(targets.count) chat…") { slimTargets = targets }
        Divider()
        Button("Sposta in…") { moveTargets = targets }
        Menu("Contesto") { contextItems(for: targets) }
        Divider()
        Button("Sposta nel Cestino", role: .destructive) { trashTargets = targets }
    }

    @ViewBuilder
    private func contextItems(for targets: [ChatSession]) -> some View {
        ForEach(store.config.contexts, id: \.self) { context in
            Button(context) { store.setContext(context, for: targets) }
        }
        Divider()
        Button("Automatico (dalla cartella)") { store.setContext(nil, for: targets) }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: return "Tutte le chat"
        case .context(let context): return context
        case .unassigned: return "Da assegnare"
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if selectedChats.count == 1, let chat = selectedChats.first {
            TranscriptView(store: store, chat: chat, actions: actions)
                .id(chat.id)
        } else if selectedChats.count > 1 {
            MultiSelectionView(store: store, chats: selectedChats, actions: actions)
        } else {
            ToolsGuideView()
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
            store.newChat(in: url.path, with: account)
        }
    }
}

// MARK: - Row

private struct ChatRow: View {
    let chat: ChatSession
    let accounts: [ClaudeAccount]
    let context: String?
    let showContext: Bool
    let isActive: Bool
    let hasAdvice: Bool
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isActive {
                    StatusDot(busy: false)
                        .help("Aperta in una sessione in corso")
                }
                Text(chat.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                if hasAdvice {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .help("Chat pesante: aprila per vedere come alleggerirla")
                }
                Spacer(minLength: 4)
                Text(relative(chat.modifiedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let preview = chat.preview, chat.title != nil {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Label(chat.projectName, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if showContext || context == nil {
                    ContextBadge(context: context)
                }
                ForEach(accounts) { account in
                    AccountBadge(account: account, compact: true)
                }
                Spacer()
                Text(formatBytes(chat.sizeBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Multi selection

private struct MultiSelectionView: View {
    @ObservedObject var store: DeckStore
    let chats: [ChatSession]
    let actions: ChatActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    symbol: "square.stack.fill",
                    tint: Theme.coral,
                    title: "\(chats.count) chat selezionate",
                    subtitle: "\(formatBytes(chats.reduce(0) { $0 + $1.sizeBytes })) in tutto. Scegli cosa farne:"
                ) { EmptyView() }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    Button { actions.merge(chats) } label: { Label("Unisci", systemImage: "arrow.triangle.merge") }
                        .prominentButton()
                        .tint(Theme.coral)
                        .help("Unisci in una sola chat")
                    ToolButton(title: "Snellisci", symbol: "arrow.down.right.and.arrow.up.left") { actions.slim(chats) }
                    ToolButton(title: "Sposta", symbol: "folder.badge.gearshape") { actions.move(chats) }
                    Menu {
                        ForEach(store.config.contexts, id: \.self) { context in
                            Button(context) { store.setContext(context, for: chats) }
                        }
                        Divider()
                        Button("Automatico (dalla cartella)") { store.setContext(nil, for: chats) }
                    } label: {
                        Label("Contesto", systemImage: "tag")
                    }
                    .menuStyle(.button)
                    .secondaryButton()
                    .fixedSize()
                    ToolButton(title: "Cestino", symbol: "trash", role: .destructive) { actions.trash(chats) }
                }
                .controlSize(.large)

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
    @State private var ordered: [ChatSession] = []
    @State private var title = ""
    @State private var targetID = ""
    @State private var openAfter = true
    @State private var accountID: String?
    @State private var isMerging = false

    private var target: ChatSession? { ordered.first { $0.id == targetID } ?? ordered.first }
    private var totalSize: Int64 { chats.reduce(0) { $0 + $1.sizeBytes } }
    private var projectChoices: [ChatSession] {
        var seen: Set<String> = []
        return ordered.filter { seen.insert($0.projectDir).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.triangle.merge", tint: Theme.coral, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unisci \(chats.count) chat")
                        .font(.title3.bold())
                    Text("Le conversazioni diventano una sola, nell'ordine qui sotto.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Ordine")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, chat in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: 20, height: 20)
                            .background(Theme.coral.opacity(0.15), in: Circle())
                            .foregroundStyle(Theme.coral)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chat.displayTitle).lineLimit(1)
                            Text("\(chat.projectName) · \(relative(chat.startedAt ?? chat.modifiedAt)) · \(formatBytes(chat.sizeBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == ordered.count - 1)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            Form {
                TextField("Nome della chat unita", text: $title)
                if projectChoices.count > 1 {
                    Picker("Salva nel progetto", selection: $targetID) {
                        ForEach(projectChoices) { chat in
                            Text(chat.projectName).tag(chat.id)
                        }
                    }
                }
                HStack {
                    Toggle("Riapri subito in \(Launcher.terminalName) con", isOn: $openAfter)
                    Picker("", selection: $accountID) {
                        ForEach(store.accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!openAfter)
                }
            }
            .formStyle(.columns)

            VStack(alignment: .leading, spacing: 6) {
                Label("Dopo l'unione le \(chats.count) chat originali vanno nel Cestino: resta solo quella unita.", systemImage: "trash")
                Label("Viene ripresa la conversazione effettiva di ogni chat; se una era compattata entra il suo riassunto. I messaggi ripetuti tra chat derivate compaiono una volta sola.", systemImage: "info.circle")
                if totalSize > 20_000_000 {
                    Label("Totale \(formatBytes(totalSize)): alla ripresa Claude Code potrebbe compattare il contesto.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    merge()
                } label: {
                    if isMerging { ProgressView().controlSize(.small) } else { Text("Unisci") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isMerging || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            ordered = chats.sorted { ($0.startedAt ?? $0.modifiedAt) < ($1.startedAt ?? $1.modifiedAt) }
            targetID = ordered.first?.id ?? ""
            title = ordered.first(where: { $0.isCustomTitle })?.title
                ?? ordered.map { String($0.displayTitle.prefix(30)) }.joined(separator: " + ")
            accountID = store.preferredAccount?.id
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard ordered.indices.contains(destination) else { return }
        ordered.swapAt(index, destination)
    }

    private func merge() {
        guard let target else { return }
        isMerging = true
        let name = title.trimmingCharacters(in: .whitespaces)
        let merged = store.merge(ordered, title: name, target: target)
        isMerging = false
        guard let merged else { return }
        if openAfter, let account = accountID.flatMap(store.account(id:)) {
            store.resume(merged, with: account)
        }
        onDone(merged.id)
        dismiss()
    }
}
