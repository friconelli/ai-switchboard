import SwiftUI
import AppKit

/// What can be done on the selected chats; ChatsView owns the sheets, the detail pane asks.
struct ChatActions {
    var rename: (ChatSession) -> Void
    var split: (ChatSession) -> Void
    var slim: ([ChatSession]) -> Void
    var move: ([ChatSession]) -> Void
    var merge: ([ChatSession]) -> Void
    var trash: ([ChatSession]) -> Void
}

/// "Riprendi" with the account and model menu, the same everywhere.
struct ResumeButton: View {
    @ObservedObject var store: DeckStore
    let chat: ChatSession
    var large = false

    var body: some View {
        let recommendation = store.recommendation(for: chat)
        let automatic = store.useRecommendedModel ? recommendation?.tier : nil
        Menu {
            Section("Account") {
                ForEach(store.accounts) { account in
                    Button("\(account.name)\(account.email.map { " — \($0)" } ?? "")") {
                        store.resume(chat, with: account)
                    }
                }
            }
            Section("Modello (con \(store.preferredAccount?.name ?? "l'account predefinito"))") {
                ForEach(ModelTier.allCases) { tier in
                    Button(tier == recommendation?.tier ? "\(tier.label) — consigliato" : tier.label) {
                        if let account = store.preferredAccount { store.resume(chat, with: account, model: tier) }
                    }
                }
            }
        } label: {
            Label(automatic.map { "Riprendi · \($0.label)" } ?? "Riprendi", systemImage: "play.fill")
        } primaryAction: {
            if let account = store.preferredAccount { store.resume(chat, with: account) }
        }
        .menuStyle(.button)
        .prominentButton()
        .tint(Theme.coral)
        .controlSize(large ? .large : .regular)
        .fixedSize()
        .help("Riprendi in \(Launcher.terminalName) con \(store.preferredAccount?.name ?? "l'account predefinito")\(automatic.map { " e \($0.label)" } ?? ""). Freccia: scegli account o modello.")
    }
}

/// A labelled secondary action, so every tool says what it does.
struct ToolButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
        }
        .secondaryButton()
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .accessibilityLabel(title)
    }
}

/// Context, model and advice for one chat, with the fix next to each problem.
struct ChatHealthView: View {
    @ObservedObject var store: DeckStore
    let chat: ChatSession
    let actions: ChatActions

    var body: some View {
        if let usage = store.usage[chat.id] {
            let insights = ModelAdvisor.insights(for: chat, usage: usage)
            let recommendation = ModelAdvisor.recommend(usage, prompts: chat.promptCount)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    chip("\(usage.lastContext / 1000)k token", symbol: "scalemass",
                         tint: usage.lastContext >= 100_000 ? .orange : .secondary,
                         help: "Contesto che Claude rilegge a ogni nuovo messaggio")
                    if let used = usage.dominantTier {
                        chip(used.label, symbol: "cpu", tint: .secondary, help: "Modello usato per la maggior parte delle risposte")
                    }
                    if let recommendation, recommendation.tier != usage.dominantTier {
                        chip("meglio \(recommendation.tier.label)", symbol: "sparkles", tint: Theme.coral,
                             help: "Consigliato in base alla storia: \(recommendation.reason)")
                    }
                    if usage.compactions > 0 {
                        chip("\(usage.compactions) compatt.", symbol: "rectangle.compress.vertical", tint: usage.compactions >= 2 ? .orange : .secondary,
                             help: "Volte in cui Claude Code ha riassunto la conversazione per farla stare nel contesto")
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)

                if !insights.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(insights) { insight in
                            HStack(spacing: 8) {
                                Image(systemName: insight.isMajor ? "exclamationmark.circle.fill" : "lightbulb")
                                    .foregroundStyle(insight.isMajor ? .orange : .yellow)
                                    .frame(width: 16)
                                Text(insight.text)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 6)
                                fix(for: insight, recommendation: recommendation)
                            }
                        }
                    }
                    .padding(10)
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private func fix(for insight: ModelAdvisor.Insight, recommendation: ModelAdvisor.Recommendation?) -> some View {
        switch insight.action {
        case .slim:
            Button("Snellisci") { actions.slim([chat]) }.controlSize(.small)
        case .split:
            Button("Dividi") { actions.split(chat) }.controlSize(.small)
        case nil:
            if let tier = recommendation?.tier, let account = store.preferredAccount {
                Button("Riprendi con \(tier.label)") { store.resume(chat, with: account, model: tier) }
                    .controlSize(.small)
            }
        }
    }

    private func chip(_ text: String, symbol: String, tint: Color, help: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .foregroundStyle(tint)
            .help(help)
    }
}

/// Shown when nothing is selected: what each tool is for.
struct ToolsGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seleziona una chat")
                        .font(.title2.bold())
                    Text("Clic per aprirla, ⌘-clic o ⇧-clic per sceglierne più di una, ⌘A per tutte.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    tool("play.fill", "Riprendi", "Riapre la chat in \(Launcher.terminalName) con l'account e il modello che scegli.")
                    tool("arrow.triangle.merge", "Unisci", "Più chat diventano una sola, nell'ordine che decidi. Le originali vanno nel Cestino.")
                    tool("scissors", "Dividi", "Una chat lunga diventa più chat, una per argomento, con un riassunto iniziale.")
                    tool("arrow.down.right.and.arrow.up.left", "Snellisci", "Toglie log, immagini e output temporanei: file più piccoli, meno token alla ripresa.")
                    tool("folder.badge.gearshape", "Sposta", "Porta la chat in un'area di lavoro o in un progetto: da lì la ritrovi con /resume.")
                    tool("tag", "Contesto", "Raggruppa le chat per ambito (es. personale, lavoro), indipendente dall'account usato.")
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func tool(_ symbol: String, _ title: String, _ text: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, tint: Theme.coral, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
