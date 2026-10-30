import SwiftUI
import AppKit

/// Sorts the topics of a long chat into different folders (containers): Claude proposes topics,
/// a description and a destination for each; the user corrects them, and every topic becomes
/// its own chat in its own folder.
struct SplitSheet: View {
    @ObservedObject var store: DeckStore
    let chat: ChatSession
    let onDone: ([ChatSession]) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Destination: Equatable {
        case folder(String)
        /// An area that does not exist yet: created when the split runs.
        case newArea(name: String, context: String)
    }

    private struct EditableTopic: Identifiable {
        let id = UUID()
        var title: String
        var description: String
        var destination: Destination
        var color: Color
    }

    private struct Group: Identifiable {
        let destination: Destination
        let topicIDs: [UUID]
        var id: String { SplitSheet.key(destination) }
    }

    private struct TopicRef: Identifiable { let id: UUID }

    @State private var source: SplitEngine.Source?
    @State private var loadError: String?
    @State private var topics: [EditableTopic] = []
    @State private var assignment: [Int: Set<UUID>] = [:]
    @State private var expanded: Set<UUID> = []
    @State private var showUnassigned = false
    @State private var addSummary = true
    @State private var trashOriginal = true
    @State private var accountID: String?
    @State private var status: String?
    @State private var problem: String?
    @State private var pickingFor: UUID?

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red, .indigo, .mint]

    private var turns: [SplitEngine.Turn] { source?.turns ?? [] }
    private var isBusy: Bool { status != nil }
    private var account: ClaudeAccount? { accountID.flatMap(store.account(id:)) ?? store.preferredAccount }
    private var unassigned: [SplitEngine.Turn] { turns.filter { assignment[$0.id]?.isEmpty ?? true } }
    private var usableTopics: [EditableTopic] {
        topics.filter { topic in
            !topic.title.trimmingCharacters(in: .whitespaces).isEmpty && turns.contains { assignment[$0.id]?.contains(topic.id) ?? false }
        }
    }

    private var groups: [Group] {
        var order: [String] = []
        var members: [String: [UUID]] = [:]
        var destinations: [String: Destination] = [:]
        for topic in topics {
            let key = Self.key(topic.destination)
            if members[key] == nil { order.append(key); destinations[key] = topic.destination }
            members[key, default: []].append(topic.id)
        }
        return order.map { Group(destination: destinations[$0]!, topicIDs: members[$0] ?? []) }
    }

    static func key(_ destination: Destination) -> String {
        switch destination {
        case .folder(let path): return path
        case .newArea(let name, let context): return "new:\(context)/\(name)"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if source != nil {
                toolbar
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if topics.isEmpty { emptyCard }
                        ForEach(groups) { groupView($0) }
                        if !topics.isEmpty { unassignedCard }
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 10)
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
        .frame(width: 900, height: 720)
        .task {
            accountID = store.preferredAccount?.id
            let chat = chat
            do {
                source = try await Task.detached(priority: .userInitiated) { try SplitEngine.analyze(chat) }.value
            } catch {
                loadError = error.localizedDescription
                return
            }
            // Sorting 100 terse messages by hand is no fun: start from a proposal.
            if turns.count >= 4 { propose() }
        }
        .sheet(item: Binding(get: { pickingFor.map(TopicRef.init) }, set: { pickingFor = $0?.id })) { ref in
            FolderPickerSheet(
                store: store,
                title: "Dove va “\(topics.first { $0.id == ref.id }?.title ?? "")”?",
                message: "La nuova chat verrà registrata in questa cartella: da lì la ritrovi con /resume.",
                confirmLabel: "Scegli"
            ) { folder in
                if let index = topics.firstIndex(where: { $0.id == ref.id }) { topics[index].destination = .folder(folder) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "scissors", tint: Theme.coral, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Smista “\(chat.displayTitle)”")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(source == nil
                     ? "Ogni argomento diventa una chat nel contenitore che scegli."
                     : "\(turns.count) turni. Ogni argomento diventa una chat nel contenitore (area o progetto) che scegli.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let status {
                ProgressView().controlSize(.small)
                Text(status).font(.callout).foregroundStyle(.secondary)
            } else if !topics.isEmpty {
                Text("\(topics.count) argomenti in \(groups.count) \(groups.count == 1 ? "contenitore" : "contenitori")")
                    .font(.callout.weight(.medium))
            }
            Spacer()
            Button {
                propose()
            } label: {
                Label(topics.isEmpty ? "Proponi smistamento" : "Riproponi", systemImage: "sparkles")
            }
            .controlSize(.regular)
            .help("Claude (Haiku) legge le tue richieste e propone argomenti, descrizioni e contenitori. Sostituisce quelli attuali.")
            .disabled(isBusy)
            Button {
                let topic = newTopic(title: "", description: "", destination: .folder(chat.workingDirectory))
                expanded.insert(topic.id)
            } label: {
                Label("Argomento", systemImage: "plus")
            }
            .help("Aggiungi un argomento a mano")
            .disabled(isBusy)
        }
    }

    private var emptyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(status == nil ? "Nessun argomento" : "Un attimo…")
                    .font(.headline)
                Text(status == nil
                     ? "Premi “Proponi smistamento”: Claude raggruppa le tue richieste per argomento, scrive una descrizione e suggerisce il contenitore giusto in base a cosa contengono già le tue cartelle. Poi correggi quello che vuoi."
                     : "Claude sta leggendo la conversazione e guardando cosa contengono le tue cartelle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Groups and topics

    private func groupView(_ group: Group) -> some View {
        let context = self.context(of: group.destination)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IconTile(
                    symbol: isNew(group.destination) ? "folder.badge.plus" : "folder.fill",
                    tint: context.map(Theme.color(forContext:)) ?? .gray,
                    size: 28
                )
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name(of: group.destination)).font(.headline)
                        ContextBadge(context: context)
                        if isNew(group.destination) {
                            Text("da creare")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text(location(of: group.destination))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(group.topicIDs.count == 1 ? "1 chat" : "\(group.topicIDs.count) chat")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ForEach(group.topicIDs, id: \.self) { id in
                if let index = topics.firstIndex(where: { $0.id == id }) { topicCard(index: index) }
            }
        }
    }

    private func topicCard(index: Int) -> some View {
        let topic = topics[index]
        let id = topic.id
        let own = turns.filter { assignment[$0.id]?.contains(id) ?? false }
        let isOpen = expanded.contains(id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(topic.color, in: Circle())
                TextField("Titolo dell'argomento", text: field(id, \.title))
                    .textFieldStyle(.plain)
                    .font(.headline)
                Spacer(minLength: 8)
                Button {
                    pickingFor = id
                } label: {
                    Label("Sposta in…", systemImage: "folder")
                }
                .controlSize(.small)
                .help("Scegli un altro contenitore: l'elenco mostra cosa contiene ognuno")
                Button {
                    for turn in assignment.keys { assignment[turn]?.remove(id) }
                    topics.removeAll { $0.id == id }
                    expanded.remove(id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Elimina argomento: i suoi turni restano senza argomento")
            }
            TextField("Descrizione: di cosa parla e a che punto è", text: field(id, \.description), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1...3)
            Button {
                if isOpen { expanded.remove(id) } else { expanded.insert(id) }
            } label: {
                Label("\(own.count) \(own.count == 1 ? "turno" : "turni")", systemImage: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if isOpen {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(own) { turn in turnRow(turn) }
                }
                .padding(.leading, 4)
            }
        }
        .padding(12)
        .background(topic.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(topic.color.opacity(0.25)))
    }

    private func turnRow(_ turn: SplitEngine.Turn) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(turn.id + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
            Text(turn.prompt)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            turnMenu(turn)
        }
        .padding(.vertical, 4)
    }

    private func turnMenu(_ turn: SplitEngine.Turn) -> some View {
        Menu {
            ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                let has = assignment[turn.id]?.contains(topic.id) ?? false
                Button("\(has ? "✓ " : "")\(index + 1). \(topic.title.isEmpty ? "Senza titolo" : topic.title)") {
                    if has { assignment[turn.id]?.remove(topic.id) } else { assignment[turn.id, default: []].insert(topic.id) }
                }
            }
            Divider()
            Button("Nuovo argomento da questo turno") {
                let topic = newTopic(title: "", description: "", destination: .folder(chat.workingDirectory))
                assignment[turn.id, default: []].insert(topic.id)
                expanded.insert(topic.id)
            }
            Button("Togli da tutti gli argomenti") { assignment[turn.id] = [] }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sposta questo turno in un altro argomento")
    }

    private var unassignedCard: some View {
        let list = unassigned
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: list.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(list.isEmpty ? .green : .orange)
                Text(list.isEmpty ? "Tutti i turni hanno un argomento" : "\(list.count) turni senza argomento")
                    .font(.headline)
                Spacer()
                if !list.isEmpty {
                    Menu("Assegna tutti a") {
                        ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                            Button("\(index + 1). \(topic.title.isEmpty ? "Senza titolo" : topic.title)") {
                                for turn in list { assignment[turn.id, default: []].insert(topic.id) }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button {
                        showUnassigned.toggle()
                    } label: {
                        Image(systemName: showUnassigned ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
            }
            if !list.isEmpty {
                Text("Non finiranno in nessuna chat nuova\(trashOriginal ? " (restano solo nell'originale, nel Cestino)" : "").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showUnassigned && !list.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { turn in turnRow(turn) }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
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
                .help("Account usato per proporre lo smistamento e scrivere i riassunti (Haiku, consumo minimo)")
            }
            .font(.callout)

            if let problem {
                Label(problem, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
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

    // MARK: - Helpers

    private func field(_ id: UUID, _ keyPath: WritableKeyPath<EditableTopic, String>) -> Binding<String> {
        Binding(
            get: { topics.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                if let index = topics.firstIndex(where: { $0.id == id }) { topics[index][keyPath: keyPath] = value }
            }
        )
    }

    private func isNew(_ destination: Destination) -> Bool {
        if case .newArea = destination { return true }
        return false
    }

    private func name(of destination: Destination) -> String {
        switch destination {
        case .folder(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .newArea(let name, _): return name
        }
    }

    private func context(of destination: Destination) -> String? {
        switch destination {
        case .folder(let path): return store.config.context(forFolder: path)
        case .newArea(_, let context): return context
        }
    }

    private func location(of destination: Destination) -> String {
        switch destination {
        case .folder(let path): return path.replacingOccurrences(of: ClaudePaths.home.path, with: "~")
        case .newArea(_, let context):
            return store.config.contextRoot(context).replacingOccurrences(of: ClaudePaths.home.path, with: "~") + "/"
        }
    }

    @discardableResult
    private func newTopic(title: String, description: String, destination: Destination) -> EditableTopic {
        let used = Set(topics.map { "\($0.color)" })
        let color = Self.palette.first { !used.contains("\($0)") } ?? Self.palette[topics.count % Self.palette.count]
        let topic = EditableTopic(title: title, description: description, destination: destination, color: color)
        topics.append(topic)
        return topic
    }

    // MARK: - Work

    private func containers() -> [ClaudeAssistant.Container] {
        var list = (store.areas + store.projects).map { folder in
            ClaudeAssistant.Container(
                path: folder.path,
                kind: folder.kind == .area ? "area" : "progetto",
                context: folder.context,
                about: store.folderSummary(folder.path).about
            )
        }
        if !list.contains(where: { $0.path == chat.workingDirectory }) {
            list.append(ClaudeAssistant.Container(
                path: chat.workingDirectory,
                kind: "cartella attuale",
                context: store.config.context(forFolder: chat.workingDirectory),
                about: store.folderSummary(chat.workingDirectory).about
            ))
        }
        return list
    }

    private func propose() {
        guard let source, !isBusy else { return }
        problem = nil
        status = "Claude sta leggendo la conversazione e guardando le tue cartelle…"
        let turns = source.turns
        let containers = containers()
        let contexts = store.config.contexts
        let current = chat.workingDirectory
        let account = account
        Task {
            do {
                let proposal = try await ClaudeAssistant.proposeTopics(
                    for: turns, containers: containers, contexts: contexts, currentFolder: current, account: account
                )
                topics = []
                assignment = [:]
                expanded = []
                for item in proposal {
                    let destination: Destination
                    if let folder = item.folder {
                        destination = .folder(folder)
                    } else if let area = item.newAreaName, let context = item.newAreaContext {
                        destination = .newArea(name: area, context: context)
                    } else {
                        destination = .folder(current)
                    }
                    let topic = newTopic(title: item.title, description: item.description, destination: destination)
                    for turn in item.turns { assignment[turn, default: []].insert(topic.id) }
                }
            } catch {
                problem = error.localizedDescription
            }
            status = nil
        }
    }

    /// The folder of a destination, creating the area when it is a new one.
    private func resolve(_ destination: Destination, created: inout [String: String]) -> String? {
        switch destination {
        case .folder(let path):
            return path
        case .newArea(let rawName, let context):
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
            let key = "\(context)/\(name)"
            if let path = created[key] { return path }
            let target = (store.config.contextRoot(context) as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target) {
                created[key] = target
                return target
            }
            guard let path = store.createArea(named: name, context: context) else { return nil }
            created[key] = path
            return path
        }
    }

    private func split() {
        guard let source else { return }
        let account = account
        problem = nil

        var createdAreas: [String: String] = [:]
        var plan: [SplitEngine.Topic] = []
        for topic in usableTopics {
            guard let folder = resolve(topic.destination, created: &createdAreas) else {
                problem = "Non riesco a creare l'area “\(name(of: topic.destination))”."
                return
            }
            plan.append(SplitEngine.Topic(
                title: topic.title.trimmingCharacters(in: .whitespaces),
                description: topic.description.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                folder: folder,
                turns: turns.filter { assignment[$0.id]?.contains(topic.id) ?? false }.map(\.id),
                summary: nil
            ))
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
