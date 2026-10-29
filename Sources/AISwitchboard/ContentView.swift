import SwiftUI

enum ChatScope: Hashable {
    case all
    case context(String)
    case unassigned
}

enum DeckSection: Hashable {
    case chats(ChatScope)
    case areas
    case active
    case accounts
    case memory
    case insights
    case compose

    /// For launching on a given page (`-debugSection insights`), used for screenshots.
    init?(debugName: String) {
        switch debugName {
        case "compose": self = .compose
        case "insights": self = .insights
        case "areas": self = .areas
        case "active": self = .active
        case "accounts": self = .accounts
        case "memory": self = .memory
        case "chats": self = .chats(.all)
        default: return nil
        }
    }
}

struct ContentView: View {
    @StateObject private var store = DeckStore()
    @State private var section: DeckSection? = .chats(.all)
    @State private var focusedChatID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                row("Nuova chat guidata", symbol: "sparkles", tint: Theme.coral)
                    .tag(DeckSection.compose)

                Section("Chat") {
                    row("Tutte", symbol: "bubble.left.and.bubble.right.fill", tint: Theme.coral, count: store.chats.count)
                        .tag(DeckSection.chats(.all))
                    ForEach(store.config.contexts, id: \.self) { context in
                        row(context, symbol: Theme.symbol(forContext: context), tint: Theme.color(forContext: context),
                            count: store.chats.filter { store.context(for: $0) == context }.count)
                            .tag(DeckSection.chats(.context(context)))
                    }
                    let unassigned = store.chats.filter { store.context(for: $0) == nil }.count
                    row("Da assegnare", symbol: "tray.fill", tint: .gray, count: unassigned, highlight: unassigned > 0 ? .gray : nil)
                        .tag(DeckSection.chats(.unassigned))
                }
                Section("Organizza") {
                    let advice = store.chats.filter { ModelAdvisor.hasMajorIssue($0, usage: store.usage[$0.id]) }.count
                    row("Consigli", symbol: "lightbulb.fill", tint: .yellow, count: advice, highlight: advice > 0 ? .orange : nil)
                        .tag(DeckSection.insights)
                        .help("Chat da snellire o dividere e modello giusto per ogni lavoro")
                    row("Aree di lavoro", symbol: "folder.fill", tint: .orange)
                        .tag(DeckSection.areas)
                        .help("Cartelle da cui far partire le chat, per contesto")
                    row("Memoria", symbol: "brain.head.profile", tint: .purple, count: store.memoryFiles.count)
                        .tag(DeckSection.memory)
                }
                Section("Sistema") {
                    row("Sessioni attive", symbol: "bolt.horizontal.fill", tint: .green, count: store.activeSessions.count,
                        highlight: store.activeSessions.isEmpty ? nil : .green)
                        .tag(DeckSection.active)
                    row("Account", symbol: "person.2.fill", tint: .blue, count: store.accounts.filter { !$0.isDefault }.count)
                        .tag(DeckSection.accounts)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                if !store.isIndexing && store.describingRemaining > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Descrivo le chat… \(store.describingRemaining)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                if store.isIndexing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Indicizzazione chat…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: store.indexProgress)
                            .tint(Theme.coral)
                    }
                    .padding(12)
                }
            }
        } detail: {
            switch section ?? .chats(.all) {
            case .chats(let scope):
                ChatsView(store: store, scope: scope, focusedChatID: $focusedChatID)
            case .areas:
                WorkspacesView(store: store) { scope in section = .chats(scope) }
            case .active:
                ActiveSessionsView(store: store) { id in
                    focusedChatID = id
                    section = .chats(.all)
                }
            case .accounts:
                AccountsView(store: store)
            case .memory:
                MemoryView(store: store)
            case .insights:
                InsightsView(store: store) { id in
                    focusedChatID = id
                    section = .chats(.all)
                }
            case .compose:
                ComposeView(store: store) { id in
                    focusedChatID = id
                    section = .chats(.all)
                }
            }
        }
        .onAppear {
            store.start()
            let defaults = UserDefaults.standard
            if let name = defaults.string(forKey: "debugSection"), let debug = DeckSection(debugName: name) { section = debug }
            if let id = defaults.string(forKey: "debugChat") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { focusedChatID = id }
            }
        }
        .alert(
            "Aprire le chat direttamente in \(Launcher.terminalName)?",
            isPresented: Binding(get: { store.pendingLaunch != nil }, set: { if !$0 { store.pendingLaunch = nil } }),
            presenting: store.pendingLaunch
        ) { launch in
            Button("Attiva e apri") { store.enableDirectLaunchAndRun(launch) }
                .keyboardShortcut(.defaultAction)
            Button("Solo questa volta: copia il comando") {
                Launcher.openTabCopyingCommand(launch.command, directory: launch.directory)
            }
            Button("Annulla", role: .cancel) {}
        } message: { launch in
            Text("Per avviare Claude nella nuova scheda l'app aggiunge a ~/.zshrc un piccolo blocco “AI Switchboard” che esegue il comando preparato per quella cartella (copia di sicurezza in ~/.ai-switchboard/zshrc.backup). Si disattiva da Account.\n\n\(launch.command)")
        }
        .alert(
            "Operazione non riuscita",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func row(_ title: String, symbol: String, tint: Color, count: Int? = nil, highlight: Color? = nil) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 24)
            Text(title)
            Spacer()
            if let count {
                if let highlight {
                    Text("\(count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(highlight.opacity(0.18), in: Capsule())
                        .foregroundStyle(highlight)
                } else {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
