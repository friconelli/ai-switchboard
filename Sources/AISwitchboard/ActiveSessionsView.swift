import SwiftUI

struct ActiveSessionsView: View {
    @ObservedObject var store: DeckStore
    let onShowChat: (String) -> Void

    @State private var killTarget: ActiveSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    symbol: "bolt.horizontal.fill",
                    tint: .green,
                    title: "Sessioni attive",
                    subtitle: "I processi Claude Code aperti adesso nei terminali, per account. Si aggiorna ogni 3 secondi."
                ) {
                    EmptyView()
                }

                if store.activeSessions.isEmpty {
                    Card {
                        EmptyStateView(symbol: "moon.zzz", title: "Nessuna sessione aperta")
                            .padding(.vertical, 20)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(store.activeSessions) { session in
                            sessionCard(session)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Sessioni attive")
        .alert(item: $killTarget) { session in
            Alert(
                title: Text("Chiudere la sessione \(session.name ?? String(session.pid))?"),
                message: Text("Il processo Claude (PID \(session.pid)) riceverà un segnale di chiusura. La conversazione resta salvata e potrai riprenderla."),
                primaryButton: .destructive(Text("Chiudi")) { store.killSession(session) },
                secondaryButton: .cancel()
            )
        }
    }

    private func sessionCard(_ session: ActiveSession) -> some View {
        let chat = store.chat(id: session.sessionId)
        let busy = session.status == "busy"

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(busy: busy)
                    Text(busy ? "Al lavoro" : "In attesa")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(busy ? .orange : .green)
                    Spacer()
                    if let account = store.account(id: session.accountID) {
                        AccountBadge(account: account)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(chat?.displayTitle ?? session.name ?? "Sessione")
                        .font(.headline)
                        .lineLimit(2)
                    Label(session.cwd.replacingOccurrences(of: ClaudePaths.home.path, with: "~"), systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Text("PID \(session.pid) · aperta \(relative(session.startedAt))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if chat != nil {
                        Button("Mostra chat") { onShowChat(session.sessionId) }
                            .secondaryButton()
                            .controlSize(.small)
                    }
                    Button(role: .destructive) {
                        killTarget = session
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Chiudi sessione")
                    .secondaryButton()
                    .controlSize(.small)
                    .tint(.red)
                }
            }
        }
    }
}
