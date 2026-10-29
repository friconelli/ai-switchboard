import SwiftUI
import AppKit

struct AccountsView: View {
    @ObservedObject var store: DeckStore

    private var namedAccounts: [ClaudeAccount] { store.accounts.filter { !$0.isDefault } }
    private var defaultAccount: ClaudeAccount? { store.accounts.first { $0.isDefault } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    symbol: "person.2.fill",
                    tint: .blue,
                    title: "Account",
                    subtitle: "Ogni account è una cartella di configurazione di Claude Code. Le chat sono condivise: puoi riprendere con un account quelle iniziate con l'altro."
                ) {
                    EmptyView()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(namedAccounts) { account in
                        accountCard(account)
                    }
                }

                if let defaultAccount {
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Configurazione predefinita (~/.claude)")
                                    .font(.subheadline.weight(.medium))
                                Text("Usata quando lanci `claude` senza alias\(defaultAccount.email.map { " · \($0)" } ?? ""). Contiene lo storico condiviso.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Apri cartella") { NSWorkspace.shared.open(defaultAccount.configDir) }
                                .secondaryButton()
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Account")
    }

    private func accountCard(_ account: ClaudeAccount) -> some View {
        let color = Theme.color(forAccount: account.name)
        let running = store.activeSessions.filter { $0.accountID == account.id }.count
        let chats = store.sessionAccounts.values.filter { $0.contains(account.id) }.count

        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Text(String(account.name.prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(color.gradient))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("claude-\(account.name)")
                                .font(.title3.bold())
                            if let plan = account.planLabel {
                                Text(plan)
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.25), in: Capsule())
                            }
                        }
                        Text(account.email ?? "non collegato")
                            .font(.callout)
                            .opacity(0.9)
                        if let organization = account.organization {
                            Text(organization)
                                .font(.caption)
                                .opacity(0.75)
                        }
                    }
                    .foregroundStyle(.white)
                    Spacer()
                }
                .padding(18)
                .background(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        stat("\(account.promptsToday)", "prompt oggi")
                        stat("\(chats)", "chat usate")
                        stat("\(running)", "aperte ora")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        info("clock", "Ultimo uso", relative(account.lastActivity))
                        info("cpu", "Modello", account.model ?? "predefinito")
                        info("puzzlepiece.extension", "Plugin attivi", "\(account.pluginCount)")
                        info(
                            account.sharesHistory ? "link" : "exclamationmark.triangle",
                            "Storico",
                            account.sharesHistory ? "condiviso" : "separato (non vede le altre chat)"
                        )
                    }

                    HStack {
                        Button {
                            newChat(with: account)
                        } label: {
                            Label("Nuova chat", systemImage: "plus.bubble")
                        }
                        .prominentButton()
                        .tint(color)
                        Button("Impostazioni") {
                            NSWorkspace.shared.open(account.configDir.appendingPathComponent("settings.json"))
                        }
                        .secondaryButton()
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(account.configDir)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Apri \(account.configDir.path)")
                        .secondaryButton()
                    }
                }
                .padding(18)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func info(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
        .font(.callout)
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
