import SwiftUI

/// Slims one or more chats in place, category by category, showing what each one saves.
struct SlimSheet: View {
    @ObservedObject var store: DeckStore
    let chats: [ChatSession]

    @Environment(\.dismiss) private var dismiss

    /// Savings measured without and with the compacted history removed (they overlap).
    private struct Estimate {
        var size = 0
        var contextTokens = 0
        var hasCompaction = false
        var keepHistory: [SlimEngine.Category: SlimEngine.Saving] = [:]
        var dropHistory: [SlimEngine.Category: SlimEngine.Saving] = [:]
    }

    @State private var estimate: Estimate?
    @State private var analyzed = 0
    @State private var enabled = Set(SlimEngine.Category.allCases.filter(\.defaultOn))
    @State private var progress: String?
    @State private var result: DeckStore.SlimResult?

    private var busy: [ChatSession] { chats.filter { store.activeSessionIDs.contains($0.id) } }

    private var savings: [SlimEngine.Category: SlimEngine.Saving] {
        guard let estimate else { return [:] }
        return enabled.contains(.compacted) ? estimate.dropHistory : estimate.keepHistory
    }

    private var bytesSaved: Int { enabled.reduce(0) { $0 + (savings[$1]?.bytes ?? 0) } }
    private var tokensSaved: Int { enabled.reduce(0) { $0 + (savings[$1]?.tokens ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.down.right.and.arrow.up.left", tint: Theme.coral, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chats.count == 1 ? "Snellisci “\(chats[0].displayTitle)”" : "Snellisci \(chats.count) chat")
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text("Toglie quello che non serve più, senza cambiare la conversazione: le chat restano le stesse in /resume.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let result {
                done(result)
            } else if let estimate {
                summary(estimate)
                categories(estimate)
                footer
            } else {
                VStack(spacing: 10) {
                    ProgressView(value: Double(analyzed), total: Double(max(1, chats.count)))
                    Text("Analizzo \(analyzed + 1) di \(chats.count)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .padding(22)
        .frame(width: 620)
        .task { await analyze() }
    }

    // MARK: - Sections

    private func summary(_ estimate: Estimate) -> some View {
        HStack(spacing: 12) {
            stat("Spazio su disco", from: formatBytes(Int64(estimate.size)), to: formatBytes(Int64(max(0, estimate.size - bytesSaved))))
            stat(
                "Contesto alla ripresa",
                from: "~\(tokens(estimate.contextTokens))",
                to: "~\(tokens(max(0, estimate.contextTokens - tokensSaved)))"
            )
        }
    }

    private func stat(_ title: String, from: String, to: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(from).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption)
                Text(to).font(.title3.bold().monospacedDigit()).foregroundStyle(Theme.coral)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func categories(_ estimate: Estimate) -> some View {
        VStack(spacing: 0) {
            ForEach(SlimEngine.Category.allCases) { category in
                let saving = (category == .compacted ? estimate.dropHistory : savings)[category] ?? SlimEngine.Saving()
                let unavailable = category == .compacted && !estimate.hasCompaction
                HStack(alignment: .top, spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { enabled.contains(category) },
                        set: { if $0 { enabled.insert(category) } else { enabled.remove(category) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(unavailable)
                    Image(systemName: category.symbol)
                        .foregroundStyle(Theme.coral)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title).font(.callout.weight(.semibold))
                        Text(unavailable ? "Nessuna compattazione in queste chat." : category.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(saving.bytes > 0 ? "−\(formatBytes(Int64(saving.bytes)))" : "—")
                            .font(.callout.monospacedDigit())
                        if saving.tokens > 0 {
                            Text("−\(tokens(saving.tokens)) token")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
                .opacity(unavailable ? 0.5 : 1)
                if category != SlimEngine.Category.allCases.last { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Ogni chat viene verificata prima di essere sostituita; la versione originale va nel Cestino.", systemImage: "checkmark.shield")
                if !busy.isEmpty {
                    Label("\(busy.count) chat aperte in una sessione verranno saltate.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                if let progress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Snellisci") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress != nil || enabled.isEmpty || bytesSaved == 0)
            }
        }
    }

    private func done(_ result: DeckStore.SlimResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "\(result.slimmed) chat snellite: \(formatBytes(Int64(result.before))) → \(formatBytes(Int64(result.after)))",
                systemImage: "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)
            if !result.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Non toccate:").font(.caption.weight(.semibold))
                    ForEach(result.problems, id: \.self) { Text($0).font(.caption) }
                }
                .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Work

    private func analyze() async {
        var total = Estimate()
        let keepSet = Set(SlimEngine.Category.allCases).subtracting([.compacted])
        let allSet = Set(SlimEngine.Category.allCases)
        for chat in chats {
            let measured = store.usage[chat.id]?.lastContext ?? 0
            let partial: Estimate? = await Task.detached(priority: .userInitiated) {
                guard let source = try? SlimEngine.analyze(chat) else { return nil }
                // The character-based estimate runs high: when Claude Code recorded the real context
                // size of the last request, use it and scale the savings to match.
                let factor = measured > 0 && source.contextTokens > 0 ? min(1, Double(measured) / Double(source.contextTokens)) : 1
                func scaled(_ savings: [SlimEngine.Category: SlimEngine.Saving]) -> [SlimEngine.Category: SlimEngine.Saving] {
                    savings.mapValues { var saving = $0; saving.tokens = Int(Double(saving.tokens) * factor); return saving }
                }
                return Estimate(
                    size: source.sizeBytes,
                    contextTokens: measured > 0 ? measured : source.contextTokens,
                    hasCompaction: source.hasCompaction,
                    keepHistory: scaled(SlimEngine.plan(source, enabled: keepSet).savings),
                    dropHistory: scaled(SlimEngine.plan(source, enabled: allSet).savings)
                )
            }.value
            if let partial {
                total.size += partial.size
                total.contextTokens += partial.contextTokens
                total.hasCompaction = total.hasCompaction || partial.hasCompaction
                merge(partial.keepHistory, into: &total.keepHistory)
                merge(partial.dropHistory, into: &total.dropHistory)
            }
            analyzed += 1
        }
        estimate = total
    }

    private func merge(_ part: [SlimEngine.Category: SlimEngine.Saving], into total: inout [SlimEngine.Category: SlimEngine.Saving]) {
        for (category, saving) in part {
            total[category, default: SlimEngine.Saving()].bytes += saving.bytes
            total[category, default: SlimEngine.Saving()].tokens += saving.tokens
            total[category, default: SlimEngine.Saving()].items += saving.items
        }
    }

    private func run() {
        progress = "Snellisco…"
        Task {
            result = await store.slim(chats, enabled: enabled) { done in
                progress = "Snellisco \(done + 1) di \(chats.count)…"
            }
            progress = nil
        }
    }

    private func tokens(_ value: Int) -> String {
        value >= 1000 ? "\(value / 1000)k" : "\(value)"
    }
}
