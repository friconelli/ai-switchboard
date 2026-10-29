import SwiftUI
import AppKit

/// Splits a chat into several chats, one per topic: turns are assigned to topics by hand or
/// with a proposal from Claude, then each topic becomes its own chat in its own folder.
struct SplitSheet: View {
    @ObservedObject var store: DeckStore
    let chat: ChatSession
    let onDone: ([ChatSession]) -> Void

    @Environment(\.dismiss) private var dismiss

    private struct EditableTopic: Identifiable {
        let id = UUID()
        var title: String
        var folder: String
        var color: Color
    }

    @State private var source: SplitEngine.Source?
    @State private var loadError: String?
    @State private var topics: [EditableTopic] = []
    @State private var assignment: [Int: Set<UUID>] = [:]
    @State private var selectedTurns: Set<Int> = []
    @State private var addSummary = true
    @State private var trashOriginal = true
    @State private var accountID: String?
    @State private var status: String?
    @State private var problem: String?
    @State private var folderTopic: UUID?

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red, .indigo, .mint]

    private var turns: [SplitEngine.Turn] { source?.turns ?? [] }
    private var isBusy: Bool { status != nil }
    private var account: ClaudeAccount? { accountID.flatMap(store.account(id:)) ?? store.preferredAccount }
    private var unassignedCount: Int { turns.filter { assignment[$0.id]?.isEmpty ?? true }.count }
    private var usableTopics: [EditableTopic] {
        topics.filter { topic in
            !topic.title.trimmingCharacters(in: .whitespaces).isEmpty && turns.contains { assignment[$0.id]?.contains(topic.id) ?? false }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let source {
                HStack(alignment: .top, spacing: 14) {
                    turnList(source)
                    topicPanel
                        .frame(width: 300)
                }
                footer
            } else if let loadError {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Impossibile leggere la chat", message: loadError)
                HStack {
                    Spacer()
                    Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                ProgressView("Leggo la conversazione…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
        .frame(width: 960, height: 700)
        .task {
            accountID = store.preferredAccount?.id
            let chat = chat
            do {
                source = try await Task.detached(priority: .userInitiated) { try SplitEngine.analyze(chat) }.value
            } catch {
                loadError = error.localizedDescription
            }
        }
        .sheet(item: Binding(get: { folderTopic.map(TopicRef.init) }, set: { folderTopic = $0?.id })) { ref in
            FolderPickerSheet(
                store: store,
                title: "Cartella per “\(topics.first { $0.id == ref.id }?.title ?? "")”",
                message: "La nuova chat verrà registrata in questa cartella: da lì la ritrovi con /resume."
            ) { folder in
                if let index = topics.firstIndex(where: { $0.id == ref.id }) { topics[index].folder = folder }
            }
        }
    }

    private struct TopicRef: Identifiable { let id: UUID }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "scissors", tint: Theme.coral, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dividi “\(chat.displayTitle)”")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(source == nil
                     ? "Ogni argomento diventa una chat a sé."
                     : "\(turns.count) turni. Crea gli argomenti, seleziona i turni e assegnali: ogni argomento diventa una chat a sé.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Turns

    private func turnList(_ source: SplitEngine.Source) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(selectedTurns.isEmpty ? "Turni" : "\(selectedTurns.count) selezionati")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Non assegnati") {
                    selectedTurns = Set(turns.filter { assignment[$0.id]?.isEmpty ?? true }.map(\.id))
                }
                .controlSize(.small)
                .disabled(unassignedCount == 0)
                Menu("Assegna a") { assignMenu(for: selectedTurns) }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(selectedTurns.isEmpty || topics.isEmpty)
            }
            List(selection: $selectedTurns) {
                ForEach(source.turns) { turn in
                    TurnRow(turn: turn, topics: assignedTopics(turn.id))
                        .tag(turn.id)
                        .contextMenu {
                            let targets = selectedTurns.contains(turn.id) ? selectedTurns : [turn.id]
                            assignMenu(for: targets)
                        }
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onKeyPress(characters: .decimalDigits) { press in
                guard let digit = Int(press.characters), digit >= 1, digit <= topics.count, !selectedTurns.isEmpty else { return .ignored }
                toggle(topics[digit - 1].id, for: selectedTurns)
                return .handled
            }
            Text("Tasti 1–9: assegna o togli i turni selezionati all'argomento corrispondente. ⇧-clic per selezionare un intervallo.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func assignedTopics(_ turn: Int) -> [TopicChip] {
        let ids = assignment[turn] ?? []
        return topics.filter { ids.contains($0.id) }.map { TopicChip(id: $0.id, title: $0.title, color: $0.color) }
    }

    @ViewBuilder
    private func assignMenu(for targets: Set<Int>) -> some View {
        ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
            let all = targets.allSatisfy { assignment[$0]?.contains(topic.id) ?? false }
            Button {
                toggle(topic.id, for: targets)
            } label: {
                Text("\(all ? "✓ " : "")\(index + 1). \(topic.title.isEmpty ? "Senza titolo" : topic.title)")
            }
        }
        if !topics.isEmpty { Divider() }
        Button("Nuovo argomento con questi turni") {
            let topic = newTopic(title: "")
            for turn in targets { assignment[turn, default: []].insert(topic.id) }
        }
        Button("Togli da tutti gli argomenti") {
            for turn in targets { assignment[turn] = [] }
        }
    }

    /// Adds the topic to every target turn, or removes it if all of them already have it.
    private func toggle(_ topic: UUID, for targets: Set<Int>) {
        let all = targets.allSatisfy { assignment[$0]?.contains(topic) ?? false }
        for turn in targets {
            if all { assignment[turn]?.remove(topic) } else { assignment[turn, default: []].insert(topic) }
        }
    }

    // MARK: - Topics

    private var topicPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Argomenti")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    proposeTopics()
                } label: {
                    Label("Proponi", systemImage: "sparkles")
                }
                .controlSize(.small)
                .help("Claude (Haiku) legge le tue domande e propone come raggrupparle")
                .disabled(isBusy)
                Button {
                    _ = newTopic(title: "")
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("Nuovo argomento")
            }

            ScrollView {
                VStack(spacing: 8) {
                    if topics.isEmpty {
                        Text("Nessun argomento. Premi “Proponi” per farli suggerire a Claude, oppure creali con +.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(Array($topics.enumerated()), id: \.element.id) { index, $topic in
                        topicCard(index: index, topic: $topic)
                    }
                }
            }
        }
    }

    private func topicCard(index: Int, topic: Binding<EditableTopic>) -> some View {
        let id = topic.wrappedValue.id
        let count = turns.filter { assignment[$0.id]?.contains(id) ?? false }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(topic.wrappedValue.color, in: Circle())
                TextField("Titolo", text: topic.title)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                Button {
                    for turn in assignment.keys { assignment[turn]?.remove(id) }
                    topics.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Elimina argomento")
            }
            HStack(spacing: 6) {
                Button {
                    selectedTurns = Set(turns.filter { assignment[$0.id]?.contains(id) ?? false }.map(\.id))
                } label: {
                    Text("\(count) turni")
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Seleziona i turni di questo argomento")
                Spacer()
                Button {
                    folderTopic = id
                } label: {
                    Label(URL(fileURLWithPath: topic.wrappedValue.folder).lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(topic.wrappedValue.folder.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                if !selectedTurns.isEmpty {
                    Button("Assegna") { toggle(id, for: selectedTurns) }
                        .controlSize(.mini)
                }
            }
        }
        .padding(10)
        .background(topic.wrappedValue.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(topic.wrappedValue.color.opacity(0.25)))
    }

    @discardableResult
    private func newTopic(title: String, folder: String? = nil) -> EditableTopic {
        let used = Set(topics.map { "\($0.color)" })
        let color = Self.palette.first { !used.contains("\($0)") } ?? Self.palette[topics.count % Self.palette.count]
        let topic = EditableTopic(title: title, folder: folder ?? chat.workingDirectory, color: color)
        topics.append(topic)
        return topic
    }

    private func proposeTopics() {
        let turns = turns
        let account = account
        status = "Claude sta leggendo la conversazione…"
        problem = nil
        Task {
            do {
                let proposal = try await ClaudeAssistant.proposeTopics(for: turns, account: account)
                topics = []
                assignment = [:]
                for item in proposal {
                    let topic = newTopic(title: item.title)
                    for turn in item.turns { assignment[turn, default: []].insert(topic.id) }
                }
            } catch {
                problem = error.localizedDescription
            }
            status = nil
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Toggle("Riassunto del contesto in testa a ogni chat", isOn: $addSummary)
                    .help("Claude scrive per ogni argomento un riassunto della conversazione originale: la nuova chat sa da dove arriva")
                Toggle("Sposta l'originale nel Cestino", isOn: $trashOriginal)
                Spacer()
                Picker("Account per Claude", selection: $accountID) {
                    ForEach(store.accounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                .fixedSize()
                .help("Account usato per proporre gli argomenti e scrivere i riassunti (Haiku, consumo minimo)")
            }
            .font(.callout)

            if unassignedCount > 0, !topics.isEmpty {
                Label(
                    "\(unassignedCount) turni non assegnati non finiranno in nessuna chat\(trashOriginal ? " (restano solo nell'originale, nel Cestino)" : "").",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let problem {
                Label(problem, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                if let status {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    split()
                } label: {
                    Text(usableTopics.count == 1 ? "Crea 1 chat" : "Dividi in \(usableTopics.count) chat")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || usableTopics.isEmpty)
            }
        }
    }

    private func split() {
        guard let source else { return }
        let account = account
        problem = nil
        var plan = usableTopics.map { topic in
            SplitEngine.Topic(
                title: topic.title.trimmingCharacters(in: .whitespaces),
                folder: topic.folder,
                turns: turns.filter { assignment[$0.id]?.contains(topic.id) ?? false }.map(\.id),
                summary: nil
            )
        }

        Task {
            if addSummary {
                status = "Claude scrive i riassunti (0/\(plan.count))…"
                do {
                    var done = 0
                    try await withThrowingTaskGroup(of: (Int, String).self) { group in
                        for (index, topic) in plan.enumerated() {
                            group.addTask {
                                (index, try await ClaudeAssistant.summary(of: source, topic: topic.title, turns: topic.turns, account: account))
                            }
                        }
                        for try await (index, summary) in group {
                            plan[index].summary = summary
                            done += 1
                            status = "Claude scrive i riassunti (\(done)/\(plan.count))…"
                        }
                    }
                } catch {
                    problem = "Riassunti non riusciti: \(error.localizedDescription) Puoi riprovare o togliere l'opzione del riassunto."
                    status = nil
                    return
                }
            }

            status = "Creo le chat…"
            let created = store.split(source, topics: plan, trashOriginal: trashOriginal)
            status = nil
            guard !created.isEmpty else { return }
            onDone(created)
            dismiss()
        }
    }
}

private struct TopicChip: Identifiable {
    let id: UUID
    let title: String
    let color: Color
}

private struct TurnRow: View {
    let turn: SplitEngine.Turn
    let topics: [TopicChip]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(turn.id + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(turn.prompt)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(relative(turn.timestamp)) · \(turn.messageCount) msg")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(topics) { topic in
                        Text(topic.title.isEmpty ? "Senza titolo" : topic.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(topic.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(topic.color)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
