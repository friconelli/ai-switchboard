import SwiftUI

/// New chat from a request: Claude finds the relevant past chats and prepares a chat that
/// already knows what they said, in the right folder and with the right model.
struct ComposeView: View {
    @ObservedObject var store: DeckStore
    let onShowChat: (String) -> Void

    private enum Step { case write, review, done }

    @State private var step = Step.write
    @State private var request = ""
    @State private var title = ""
    @State private var folder = ""
    @State private var suggestions: [ComposeEngine.SuggestedChat] = []
    @State private var included: Set<String> = []
    @State private var model: ModelTier?
    @State private var modelReason = ""
    @State private var accountID: String?
    @State private var sendRequest = true
    @State private var status: String?
    @State private var problem: String?
    @State private var pickingFolder = false
    @State private var created: ChatSession?

    private var account: ClaudeAccount? { accountID.flatMap(store.account(id:)) ?? store.preferredAccount }
    private var trimmedRequest: String { request.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    symbol: "sparkles",
                    tint: Theme.coral,
                    title: "Nuova chat guidata",
                    subtitle: "Scrivi cosa vuoi fare. Claude cerca nelle tue chat quello che serve, sceglie cartella e modello e prepara una chat che parte già informata."
                ) { EmptyView() }

                stepIndicator

                requestCard

                if step != .write {
                    reviewCard
                }

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if step == .done, let created {
                    doneCard(created)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Nuova chat guidata")
        .onAppear { if accountID == nil { accountID = store.preferredAccount?.id } }
        .sheet(isPresented: $pickingFolder) {
            FolderPickerSheet(
                store: store,
                title: "Cartella della nuova chat",
                message: "Claude lavorerà in questa cartella e da lì ritroverai la chat con /resume."
            ) { folder = $0 }
        }
    }

    // MARK: - Steps

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            stepLabel(1, "Richiesta", active: step == .write)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            stepLabel(2, "Storico e impostazioni", active: step == .review)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            stepLabel(3, "Avvio", active: step == .done)
        }
    }

    private func stepLabel(_ number: Int, _ text: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(active ? Theme.coral : Color.primary.opacity(0.08), in: Circle())
            Text(text)
                .font(.callout.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private var requestCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cosa vuoi fare?")
                    .font(.headline)
                ZStack(alignment: .topLeading) {
                    if request.isEmpty {
                        Text("Es. “Sul sito del cliente aggiungi il calcolo delle spedizioni a peso, come avevamo deciso la settimana scorsa”")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $request)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 110)
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Picker("Account", selection: $accountID) {
                        ForEach(store.accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                    .fixedSize()
                    .help("Account usato sia per cercare (Haiku, consumo minimo) sia per la nuova chat")
                    Spacer()
                    if step == .write {
                        if let status {
                            ProgressView().controlSize(.small)
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                        Button {
                            propose()
                        } label: {
                            Label("Cerca nelle mie chat", systemImage: "sparkle.magnifyingglass")
                        }
                        .prominentButton()
                        .tint(Theme.coral)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(trimmedRequest.isEmpty || status != nil)
                    } else if step == .review {
                        Button("Modifica la richiesta") { step = .write }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var reviewCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Storico da usare")
                        .font(.headline)
                    if suggestions.isEmpty {
                        Text("Nessuna chat passata sembra collegata: partirà una chat nuova, senza storico.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(suggestions, id: \.id) { suggestion in
                        if let chat = store.chat(id: suggestion.id) {
                            HStack(alignment: .top, spacing: 10) {
                                SelectionCheckbox(isOn: included.contains(chat.id)) {
                                    if included.contains(chat.id) { included.remove(chat.id) } else { included.insert(chat.id) }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text("\(chat.projectName) · \(relative(chat.modifiedAt)) · \(suggestion.reason)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    Menu {
                        ForEach(store.chats.filter { chat in !suggestions.contains { $0.id == chat.id } }.prefix(40)) { chat in
                            Button(chat.displayTitle) {
                                suggestions.append(ComposeEngine.SuggestedChat(id: chat.id, reason: "aggiunta da te"))
                                included.insert(chat.id)
                            }
                        }
                    } label: {
                        Label("Aggiungi un'altra chat", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Titolo").foregroundStyle(.secondary)
                        TextField("Titolo", text: $title).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Cartella").foregroundStyle(.secondary)
                        HStack {
                            Text(folder.isEmpty ? "Scegli una cartella" : folder.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(folder.isEmpty ? .orange : .primary)
                            Button("Cambia…") { pickingFolder = true }
                        }
                    }
                    GridRow {
                        Text("Modello").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: $model) {
                                Text("Predefinito").tag(ModelTier?.none)
                                ForEach(ModelTier.allCases) { Text($0.label).tag(Optional($0)) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                            if !modelReason.isEmpty {
                                Text("Consigliato: \(modelReason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    GridRow {
                        Text("")
                        Toggle("Invia subito la richiesta come primo messaggio", isOn: $sendRequest)
                    }
                }

                HStack {
                    if let status {
                        ProgressView().controlSize(.small)
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        start()
                    } label: {
                        Label(included.isEmpty ? "Avvia senza storico" : "Crea e avvia in \(Launcher.terminalName)", systemImage: "play.fill")
                    }
                    .prominentButton()
                    .tint(Theme.coral)
                    .controlSize(.large)
                    .disabled(folder.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty || status != nil || step == .done)
                }
            }
        }
    }

    private func doneCard(_ chat: ChatSession) -> some View {
        Card {
            HStack {
                Label("“\(chat.displayTitle)” è pronta e si sta aprendo in \(Launcher.terminalName).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Mostra nella lista") { onShowChat(chat.id) }
                Button("Nuova richiesta") { reset() }
                    .prominentButton()
                    .tint(Theme.coral)
            }
        }
    }

    // MARK: - Work

    private func propose() {
        problem = nil
        status = "Claude sta cercando nelle tue chat…"
        let request = trimmedRequest
        let chats = store.chats
        let folders = store.areas + store.projects
        let descriptions = store.descriptions
        let account = account
        Task {
            do {
                let proposal = try await ComposeEngine.propose(request: request, chats: chats, folders: folders, descriptions: descriptions, account: account)
                title = proposal.title
                folder = proposal.folder ?? proposal.chats.first.flatMap { store.chat(id: $0.id)?.workingDirectory } ?? ""
                suggestions = proposal.chats
                included = Set(proposal.chats.map(\.id))
                model = proposal.model
                modelReason = proposal.model.map { "\($0.label), \(proposal.modelReason)" } ?? ""
                step = .review
            } catch {
                problem = error.localizedDescription
            }
            status = nil
        }
    }

    private func start() {
        guard let account else { return }
        problem = nil
        let sources = suggestions.compactMap { included.contains($0.id) ? store.chat(id: $0.id) : nil }
        let request = trimmedRequest
        Task {
            var summary: String?
            if !sources.isEmpty {
                status = "Leggo \(sources.count) chat…"
                let parsed = await Task.detached(priority: .userInitiated) {
                    sources.compactMap { try? SplitEngine.analyze($0) }
                }.value
                status = "Claude scrive il contesto della nuova chat…"
                do {
                    summary = try await ComposeEngine.summary(request: request, sources: parsed, account: account)
                } catch {
                    problem = "Non sono riuscito a preparare il contesto: \(error.localizedDescription)"
                    status = nil
                    return
                }
            }
            status = "Avvio…"
            let chat = store.startComposed(
                title: title.trimmingCharacters(in: .whitespaces),
                folder: folder,
                summary: summary,
                sources: sources,
                request: request,
                sendRequest: sendRequest,
                account: account,
                model: model
            )
            status = nil
            created = chat
            step = chat == nil && summary != nil ? .review : .done
            if chat == nil && summary == nil { reset() }
        }
    }

    private func reset() {
        step = .write
        request = ""
        title = ""
        folder = ""
        suggestions = []
        included = []
        model = nil
        modelReason = ""
        created = nil
        problem = nil
    }
}
