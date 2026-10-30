import SwiftUI
import Charts

/// Consumption from the transcripts' own token counts, and what to do about it: chats to slim
/// or split, and which model fits the kind of work done in each chat.
struct InsightsView: View {
    @ObservedObject var store: DeckStore
    let onShowChat: (String) -> Void

    @State private var slimTargets: [ChatSession] = []
    @State private var splitTarget: ChatSession?

    private struct WeekPoint: Identifiable {
        var id: String { "\(week)-\(tier)" }
        let week: Date
        let tier: String
        let value: Double
    }

    private struct ChatAdvice: Identifiable {
        var id: String { chat.id }
        let chat: ChatSession
        let usage: ChatUsage
        let insights: [ModelAdvisor.Insight]
        let recent: Double
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Derived data

    private var monthAgo: String { Self.dayFormatter.string(from: Date().addingTimeInterval(-30 * 86_400)) }

    private func recentWeight(_ usage: ChatUsage) -> Double {
        let since = monthAgo
        return usage.daily.filter { $0.key >= since }.values.reduce(0) { $0 + $1.values.reduce(0, +) }
    }

    private var weeks: [WeekPoint] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.dateInterval(of: .weekOfYear, for: Date().addingTimeInterval(-9 * 7 * 86_400))?.start ?? .distantPast
        var totals: [Date: [String: Double]] = [:]
        for usage in store.usage.values {
            for (day, tiers) in usage.daily {
                guard let date = Self.dayFormatter.date(from: day), date >= start,
                      let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { continue }
                for (tier, value) in tiers { totals[week, default: [:]][tier, default: 0] += value }
            }
        }
        return totals.flatMap { week, tiers in
            tiers.map { WeekPoint(week: week, tier: ModelTier(rawValue: $0.key)?.label ?? "Altro", value: $0.value / 1_000_000) }
        }
        .sorted { $0.week < $1.week }
    }

    private var advice: [ChatAdvice] {
        store.chats.compactMap { chat in
            guard let usage = store.usage[chat.id] else { return nil }
            let insights = store.insights(for: chat)
            guard !insights.isEmpty else { return nil }
            return ChatAdvice(chat: chat, usage: usage, insights: insights, recent: recentWeight(usage))
        }
        .sorted { ($0.recent, Double($0.usage.lastContext)) > ($1.recent, Double($1.usage.lastContext)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    symbol: "lightbulb.fill",
                    tint: .yellow,
                    title: "Consigli",
                    subtitle: "Calcolati dai token che Claude Code registra a ogni risposta, in tutte le chat dei tuoi account."
                ) {
                    if store.isScanningUsage { ProgressView().controlSize(.small) }
                }

                if store.usage.isEmpty {
                    Card {
                        Text(store.isScanningUsage ? "Leggo i consumi delle chat…" : "Nessun dato di consumo nelle chat.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    stats
                    chart
                    tips
                    models
                    chatList
                }
            }
            .padding(24)
        }
        .navigationTitle("Consigli")
        .sheet(isPresented: Binding(get: { !slimTargets.isEmpty }, set: { if !$0 { slimTargets = [] } })) {
            SlimSheet(store: store, chats: slimTargets)
        }
        .sheet(item: $splitTarget) { chat in
            SplitSheet(store: store, chat: chat) { _ in }
        }
    }

    // MARK: - Sections

    private var stats: some View {
        let all = store.usage.values
        let recent = all.reduce(0) { $0 + recentWeight($1) }
        let weighted = all.reduce(0) { $0 + $1.weighted }
        let cacheShare = weighted > 0 ? all.reduce(0) { $0 + Double($1.cacheReadTokens) * 0.1 } / weighted : 0
        let heavy = store.chats.filter { ($0.modifiedAt > Date().addingTimeInterval(-30 * 86_400)) && store.contextTokens(for: $0) >= 100_000 }.count
        var tiers: [String: Int] = [:]
        for usage in all { for (tier, count) in usage.models { tiers[tier, default: 0] += count } }
        let total = max(1, tiers.values.reduce(0, +))
        let top = tiers.max { $0.value < $1.value }

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            statCard("Consumo ultimi 30 giorni", value: "\(String(format: "%.1f", recent / 1_000_000)) M", note: "token equivalenti", symbol: "chart.bar.fill", tint: Theme.coral)
            statCard("Contesto riletto", value: "\(Int(cacheShare * 100))%", note: "del consumo totale", symbol: "arrow.triangle.2.circlepath", tint: .orange)
            statCard("Chat pesanti", value: "\(heavy)", note: "oltre 100k token, ultimi 30 giorni", symbol: "scalemass.fill", tint: .red)
            statCard("Modello più usato", value: top.flatMap { ModelTier(rawValue: $0.key)?.label } ?? "—",
                     note: top.map { "\($0.value * 100 / total)% delle risposte" } ?? "", symbol: "cpu", tint: .blue)
        }
        .help("Token equivalenti: input + scrittura in cache × 1,25 + lettura dalla cache × 0,1 + output × 5. È una stima del peso relativo, non un costo.")
    }

    private func statCard(_ title: String, value: String, note: String, symbol: String, tint: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.title.bold().monospacedDigit())
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chart: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Consumo per settimana")
                    .font(.headline)
                Chart(weeks) { point in
                    BarMark(
                        x: .value("Settimana", point.week, unit: .weekOfYear),
                        y: .value("Milioni di token equivalenti", point.value)
                    )
                    .foregroundStyle(by: .value("Modello", point.tier))
                }
                .chartForegroundStyleScale(["Haiku": Color.teal, "Sonnet": Theme.coral, "Opus": Color.purple, "Altro": Color.gray])
                .chartYAxisLabel("M token eq.")
                .frame(height: 180)
            }
        }
    }

    private var tips: some View {
        let all = Array(store.usage.values)
        let weighted = all.reduce(0) { $0 + $1.weighted }
        let cacheShare = weighted > 0 ? all.reduce(0) { $0 + Double($1.cacheReadTokens) * 0.1 } / weighted : 0
        let list = advice
        let downgrade = list.filter { $0.insights.contains { $0.kind == .modelDown } }.count
        let upgrade = list.filter { $0.insights.contains { $0.kind == .modelUp } }.count
        let slimmable = list.filter { $0.insights.contains { $0.action == .slim } }.count
        let splittable = list.filter { $0.insights.contains { $0.kind == .compactions } }.count

        var lines: [(String, String)] = []
        if cacheShare > 0.3 {
            lines.append(("arrow.triangle.2.circlepath", "Il \(Int(cacheShare * 100))% del consumo è contesto riletto: in una chat lunga ogni messaggio ricarica tutta la storia. Quando cambi argomento apri una chat nuova (o usa /clear), invece di continuare nella stessa."))
        }
        if slimmable > 0 {
            lines.append(("arrow.down.right.and.arrow.up.left", "\(slimmable) chat hanno contesto pesante, molte immagini o file grandi: snellirle riduce quello che Claude rilegge alla ripresa."))
        }
        if splittable > 0 {
            lines.append(("scissors", "\(splittable) chat sono state compattate più volte: dividerle per argomento dà chat brevi e mirate, e i riassunti di compattazione smettono di perdere dettagli."))
        }
        if downgrade > 0 {
            lines.append(("hare", "\(downgrade) chat sono fatte con un modello più potente del necessario: con il modello consigliato consumi meno quota."))
        }
        if upgrade > 0 {
            lines.append(("tortoise", "\(upgrade) chat di sviluppo lungo potrebbero andare meglio con Opus: meno tentativi e correzioni spesso compensano il costo maggiore."))
        }
        lines.append(("doc.text", "Metti regole e contesto stabile nel CLAUDE.md dell'area o del progetto: viene letto a ogni avvio e risparmia spiegazioni ripetute."))

        return VStack(alignment: .leading, spacing: 10) {
            Text("Come risparmiare")
                .font(.title3.bold())
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(lines, id: \.1) { symbol, text in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol)
                                .foregroundStyle(Theme.coral)
                                .frame(width: 22)
                            Text(text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var models: some View {
        var used: [ModelTier: Int] = [:]
        var recommended: [ModelTier: Int] = [:]
        for chat in store.chats {
            guard let usage = store.usage[chat.id] else { continue }
            if let tier = usage.dominantTier { used[tier, default: 0] += 1 }
            if let tier = ModelAdvisor.recommend(usage, prompts: chat.promptCount)?.tier { recommended[tier, default: 0] += 1 }
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Modello giusto")
                .font(.title3.bold())
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 0) {
                        ForEach(ModelTier.allCases) { tier in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tier.label).font(.headline)
                                Text("usato in \(used[tier] ?? 0) chat")
                                    .font(.callout)
                                Text("consigliato per \(recommended[tier] ?? 0)")
                                    .font(.callout)
                                    .foregroundStyle(Theme.coral)
                                Text(tierUse(tier))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider()
                    Toggle(isOn: Binding(get: { store.useRecommendedModel }, set: { store.useRecommendedModel = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Usa il modello consigliato quando riprendi o avvii una chat")
                            Text("Riprendi aggiunge --model in base alla storia della chat; una nuova chat usa il modello più adatto alle chat della stessa cartella. Dal menu di Riprendi puoi sempre scegliere a mano.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
        }
    }

    private func tierUse(_ tier: ModelTier) -> String {
        switch tier {
        case .haiku: return "Domande veloci, riordino file, comandi semplici."
        case .sonnet: return "Sviluppo quotidiano, siti, script, controlli."
        case .opus: return "Progetti lunghi e intricati, molte modifiche, architettura."
        }
    }

    private var chatList: some View {
        let list = advice.prefix(40)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Chat da sistemare")
                    .font(.title3.bold())
                Text("\(advice.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                let slimmable = advice.filter { $0.insights.contains { $0.action == .slim } }.map(\.chat)
                if !slimmable.isEmpty {
                    Button {
                        slimTargets = slimmable
                    } label: {
                        Label("Snellisci tutte (\(slimmable.count))", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .prominentButton()
                    .tint(Theme.coral)
                }
            }
            Text("Ordinate per consumo negli ultimi 30 giorni.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Card(padding: 6) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list)) { item in
                        adviceRow(item)
                        if item.id != list.last?.id { Divider().padding(.leading, 12) }
                    }
                }
            }
        }
    }

    private func adviceRow(_ item: ChatAdvice) -> some View {
        let recommendation = store.recommendation(for: item.chat)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(item.chat.displayTitle) { onShowChat(item.chat.id) }
                        .buttonStyle(.link)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.chat.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.recent > 0 {
                        Text("\(String(format: "%.1f", item.recent / 1_000_000)) M in 30 gg")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                ForEach(item.insights) { insight in
                    Label(insight.text, systemImage: symbol(insight.kind))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if item.insights.contains(where: { $0.action == .slim }) {
                    Button { slimTargets = [item.chat] } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .help("Snellisci")
                        .secondaryButton()
                }
                if item.insights.contains(where: { $0.action == .split }) {
                    Button { splitTarget = item.chat } label: { Image(systemName: "scissors") }
                        .help("Dividi in argomenti")
                        .secondaryButton()
                }
                if let recommendation, let account = store.preferredAccount {
                    Button {
                        store.resume(item.chat, with: account, model: recommendation.tier)
                    } label: {
                        Label(recommendation.tier.label, systemImage: "play.fill")
                    }
                    .help("Riprendi con \(recommendation.tier.label): \(recommendation.reason)")
                    .secondaryButton()
                }
            }
        }
        .padding(12)
    }

    private func symbol(_ kind: ModelAdvisor.Insight.Kind) -> String {
        switch kind {
        case .slimGain: return "arrow.down.right.and.arrow.up.left"
        case .compactions: return "rectangle.compress.vertical"
        case .modelDown: return "hare"
        case .modelUp: return "tortoise"
        }
    }
}
