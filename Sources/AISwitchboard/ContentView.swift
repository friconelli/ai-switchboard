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
}

struct ContentView: View {
    @StateObject private var store = DeckStore()
    @State private var section: DeckSection? = .chats(.all)
    @State private var focusedChatID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Chat") {
                    row("Tutte", symbol: "bubble.left.and.bubble.right.fill", tint: Theme.coral, count: store.chats.count)
                        .tag(DeckSection.chats(.all))
                    ForEach(store.config.contexts, id: \.self) { context in
                        row(context, symbol: Theme.symbol(forContext: context), tint: Theme.color(forContext: context),
                            count: store.chats.filter { store.context(for: $0) == context }.count)
                            .tag(DeckSection.chats(.context(context)))
                    }
                    row("Da assegnare", symbol: "tray.fill", tint: .gray,
                        count: store.chats.filter { store.context(for: $0) == nil }.count)
                        .tag(DeckSection.chats(.unassigned))
                }
                Section("Gestione") {
                row("Aree di lavoro", symbol: "folder.fill", tint: .orange, count: store.areas.count)
                    .tag(DeckSection.areas)
                row("Sessioni attive", symbol: "bolt.horizontal.fill", tint: .green, count: store.activeSessions.count)
                    .tag(DeckSection.active)
                row("Account", symbol: "person.2.fill", tint: .blue, count: store.accounts.filter { !$0.isDefault }.count)
                    .tag(DeckSection.accounts)
                row("Memoria", symbol: "brain.head.profile", tint: .purple, count: store.memoryFiles.count)
                    .tag(DeckSection.memory)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
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
            }
        }
        .onAppear { store.start() }
        .alert(
            "Quasi fatto",
            isPresented: Binding(get: { store.noticeMessage != nil }, set: { if !$0 { store.noticeMessage = nil } })
        ) {
            Button("Apri Accessibilità") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.noticeMessage ?? "")
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

    private func row(_ title: String, symbol: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 24)
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
