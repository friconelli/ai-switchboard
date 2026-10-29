import SwiftUI

enum DeckSection: Hashable {
    case chats
    case active
    case accounts
    case memory
}

struct ContentView: View {
    @StateObject private var store = DeckStore()
    @State private var section: DeckSection? = .chats
    @State private var focusedChatID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                row("Chat", symbol: "bubble.left.and.bubble.right.fill", tint: Theme.coral, count: store.chats.count)
                    .tag(DeckSection.chats)
                row("Sessioni attive", symbol: "bolt.horizontal.fill", tint: .green, count: store.activeSessions.count)
                    .tag(DeckSection.active)
                row("Account", symbol: "person.2.fill", tint: .blue, count: store.accounts.filter { !$0.isDefault }.count)
                    .tag(DeckSection.accounts)
                row("Memoria", symbol: "brain.head.profile", tint: .purple, count: store.memoryFiles.count)
                    .tag(DeckSection.memory)
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
            switch section ?? .chats {
            case .chats:
                ChatsView(store: store, focusedChatID: $focusedChatID)
            case .active:
                ActiveSessionsView(store: store) { id in
                    focusedChatID = id
                    section = .chats
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
