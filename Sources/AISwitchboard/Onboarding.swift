import SwiftUI
import AppKit

/// Claude Code accounts are configuration folders: `~/.claude` plus one `~/.claude-<name>` per
/// extra account, selected with `CLAUDE_CONFIG_DIR`. Adding one creates the folder and opens
/// Claude in it, which asks to log in.
enum AccountSetup {
    struct Pending: Identifiable {
        var id: String { url.path }
        let name: String
        let url: URL
    }

    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return String(cleaned.unicodeScalars.filter { allowed.contains($0) && $0.isASCII })
    }

    /// Creates `~/.claude-<name>`; with `shareHistory` its chats go to the shared `~/.claude/projects`,
    /// so the app (and `/resume` from either account) sees all of them.
    static func create(name: String, shareHistory: Bool) throws -> URL {
        let fm = FileManager.default
        let slug = slug(name)
        guard !slug.isEmpty else { throw ChatOperationError.io("Scegli un nome con lettere o numeri") }
        let dir = ClaudePaths.home.appendingPathComponent(".claude-\(slug)")
        guard !fm.fileExists(atPath: dir.path) else { throw ChatOperationError.io("Esiste già un account “\(slug)”") }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if shareHistory {
            let shared = ClaudePaths.home.appendingPathComponent(".claude/projects")
            try fm.createDirectory(at: shared, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: dir.appendingPathComponent("projects"), withDestinationURL: shared)
        }
        return dir
    }

    /// Account folders not logged in yet.
    static func pending(known: [ClaudeAccount]) -> [Pending] {
        let fm = FileManager.default
        let home = ClaudePaths.home
        var result: [Pending] = []
        if !fm.fileExists(atPath: home.appendingPathComponent(".claude.json").path) {
            result.append(Pending(name: "predefinito", url: home.appendingPathComponent(".claude")))
        }
        let entries = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        for entry in entries.sorted() where entry.hasPrefix(".claude-") {
            let dir = home.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  !known.contains(where: { $0.configDir.path == dir.path && $0.email != nil }) else { continue }
            result.append(Pending(name: String(entry.dropFirst(".claude-".count)), url: dir))
        }
        return result
    }

    static func loginCommand(for dir: URL) -> String {
        dir.lastPathComponent == ".claude" ? "claude" : "CLAUDE_CONFIG_DIR='\(dir.path)' claude"
    }
}

/// First-run setup: accounts, folders, contexts and first work areas. Nothing is preset, and
/// every step can be skipped: skipping closes the setup and it stays reachable from Account.
struct OnboardingView: View {
    @ObservedObject var store: DeckStore
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, accounts, folders, contexts, areas

        var title: String {
            switch self {
            case .welcome: return "Benvenuto"
            case .accounts: return "I tuoi account Claude"
            case .folders: return "Dove stanno le cose"
            case .contexts: return "Contesti"
            case .areas: return "Prime aree di lavoro"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: return ""
            case .accounts: return "Ogni account di Claude Code è una cartella di configurazione. Con un solo account basta quello predefinito."
            case .folders: return "Le chat che non riguardano un progetto di codice partono da cartelle dedicate, così i progetti restano puliti."
            case .contexts: return "Gruppi in cui dividere le chat, indipendenti dall'account usato. Ne serve almeno uno."
            case .areas: return "Un'area è una cartella da cui far partire le chat su un'attività. Puoi crearle anche dopo."
            }
        }

        var symbol: String {
            switch self {
            case .welcome: return "point.3.connected.trianglepath.dotted"
            case .accounts: return "person.2.fill"
            case .folders: return "folder.fill"
            case .contexts: return "tag.fill"
            case .areas: return "square.grid.2x2.fill"
            }
        }
    }

    @State private var step = Step.welcome
    @State private var isFirstRun = true
    @State private var newAccountName = ""
    @State private var shareHistory = true
    @State private var accountProblem: String?
    @State private var chatRoot = ""
    @State private var projectsRoot = ""
    @State private var useProjects = true
    @State private var contexts: [String] = []
    @State private var newContext = ""
    @State private var defaultProjectContext = ""
    @State private var areaNames: [String: String] = [:]
    @State private var createdAreas: [String: [String]] = [:]
    @State private var autoDescriptions = true
    @State private var refresh = 0

    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let steps = Step.allCases.filter { $0 != .welcome }

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome { header }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .welcome: welcome
                    case .accounts: accounts
                    case .folders: folders
                    case .contexts: contextsStep
                    case .areas: areas
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, step == .welcome ? 36 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .onAppear(perform: load)
        .onReceive(poll) { _ in
            if step == .accounts { store.reloadAccounts(); refresh += 1 }
            // Screenshots: `-debugOnboardingAutoAdvance YES` walks through the steps by itself.
            if UserDefaults.standard.bool(forKey: "debugOnboardingAutoAdvance"), step != .areas { next() }
        }
    }

    // MARK: - Frame

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Theme.coral : Color.primary.opacity(0.12))
                        .frame(height: 4)
                }
            }
            HStack(spacing: 14) {
                IconTile(symbol: step.symbol, tint: Theme.coral, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Passo \(step.rawValue) di \(steps.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.coral)
                    Text(step.title)
                        .font(.title.bold())
                }
            }
            Text(step.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(isFirstRun ? "Salta per ora" : "Chiudi") { skip() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help(isFirstRun
                      ? "Chiude la configurazione senza cambiare nulla: la riapri da Account → Configurazione guidata"
                      : "Chiude la configurazione")
            Spacer()
            if step != .welcome {
                Button("Indietro") { step = Step(rawValue: step.rawValue - 1)! }
                    .controlSize(.large)
            }
            Button(primaryLabel) { step == .areas ? finish() : next() }
                .prominentButton()
                .tint(Theme.coral)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 16)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Configura"
        case .areas: return "Fine"
        default: return "Avanti"
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            IconTile(symbol: Step.welcome.symbol, tint: Theme.coral, size: 76)
            VStack(spacing: 8) {
                Text("AI Switchboard")
                    .font(.system(size: 34, weight: .bold))
                Text("Tutte le tue chat di Claude Code in un posto solo, anche con più account: cercale, riprendile, uniscile o dividile, tienile leggere e falle partire dalla cartella giusta.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                welcomeRow("person.2.fill", "Account", "Collega quelli che hai già o aggiungine di nuovi")
                welcomeRow("folder.fill", "Cartelle", "Scegli dove tenere le chat e i progetti")
                welcomeRow("tag.fill", "Contesti", "Dividi le chat a modo tuo, per esempio personale e lavoro")
                welcomeRow("square.grid.2x2.fill", "Aree di lavoro", "Crea le prime cartelle da cui far partire le chat")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(verbatim: "Ci vuole un minuto, puoi saltare ogni passo e riaprire la configurazione quando vuoi da Account. Tutto resta sul tuo Mac: l'app legge e scrive solo le cartelle di Claude Code e quelle che scegli tu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func welcomeRow(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: Theme.coral, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var accounts: some View {
        let _ = refresh
        let pending = AccountSetup.pending(known: store.accounts)
            .filter { item in !store.accounts.contains { $0.configDir.path == item.url.path } }
        return VStack(alignment: .leading, spacing: 12) {
            if store.accounts.isEmpty && pending.isEmpty {
                note("Non ho trovato Claude Code configurato su questo Mac. Installalo (claude.com/claude-code), poi aggiungi qui il tuo account.", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            ForEach(store.accounts) { account in
                accountRow(
                    initial: account.isDefault ? "P" : String(account.name.prefix(1)).uppercased(),
                    color: Theme.color(forAccount: account.name),
                    title: account.isDefault ? "Predefinito" : account.name,
                    detail: [account.email, account.planLabel].compactMap { $0 }.joined(separator: " · "),
                    status: account.email == nil ? nil : "Collegato"
                ) {
                    if account.email == nil { Button("Accedi") { store.login(configDir: account.configDir) } }
                }
            }
            ForEach(pending) { item in
                accountRow(
                    initial: String(item.name.prefix(1)).uppercased(),
                    color: .gray,
                    title: item.name,
                    detail: "In attesa del login nella finestra del terminale",
                    status: nil
                ) {
                    Button("Apri login") { store.login(configDir: item.url) }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Aggiungi un account").font(.headline)
                    HStack(spacing: 8) {
                        TextField("Nome breve (es. lavoro)", text: $newAccountName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addAccount)
                        Button("Aggiungi e accedi", action: addAccount)
                            .disabled(AccountSetup.slug(newAccountName).isEmpty)
                    }
                    .controlSize(.large)
                    Toggle("Condividi lo storico delle chat con gli altri account", isOn: $shareHistory)
                    let folder = AccountSetup.slug(newAccountName).isEmpty ? "nome" : AccountSetup.slug(newAccountName)
                    Text(verbatim: "Crea la cartella ~/.claude-\(folder) e apre Claude nel terminale: fai il login con l'account che vuoi usare. Da terminale lo userai con CLAUDE_CONFIG_DIR=~/.claude-\(folder) claude.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let accountProblem {
                        Text(accountProblem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func accountRow<Accessory: View>(
        initial: String, color: Color, title: String, detail: String, status: String?,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Text(initial)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            accessory()
            if let status {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                folderRow(
                    "Cartella delle chat",
                    path: $chatRoot,
                    help: "Qui l'app crea una sottocartella per ogni contesto e, dentro, le aree di lavoro."
                )
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $useProjects) {
                        Text("Ho una cartella con i progetti di codice").font(.headline)
                    }
                    if useProjects {
                        folderRow(
                            nil,
                            path: $projectsRoot,
                            help: "Ogni sottocartella è un progetto: le chat partite da lì vengono riconosciute."
                        )
                    }
                }
            }
        }
    }

    private func folderRow(_ title: String?, path: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(path.wrappedValue.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Scegli…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: path.wrappedValue).deletingLastPathComponent()
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var contextsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("Nome del contesto", text: $newContext)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addContext)
                        Button("Aggiungi", action: addContext)
                            .disabled(newContext.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.large)
                    let suggestions = ["Personale", "Lavoro", "Clienti", "Studio"].filter { !contexts.contains($0) }
                    if !suggestions.isEmpty {
                        HStack(spacing: 6) {
                            Text("Suggeriti").font(.caption).foregroundStyle(.secondary)
                            ForEach(suggestions, id: \.self) { name in
                                Button { contexts.append(name) } label: {
                                    Label(name, systemImage: "plus")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.07), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            if contexts.isEmpty {
                note("Aggiungi almeno un contesto per continuare, oppure salta la configurazione.", symbol: "info.circle.fill", tint: .secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(contexts, id: \.self) { context in
                        HStack(spacing: 10) {
                            IconTile(symbol: Theme.symbol(forContext: context), tint: Theme.color(forContext: context), size: 28)
                            Text(context).font(.headline)
                            Spacer()
                            Button { contexts.removeAll { $0 == context } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Togli “\(context)”")
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            if useProjects && !contexts.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Contesto dei progetti di codice", selection: $defaultProjectContext) {
                            Text("Nessuno (da assegnare)").tag("")
                            ForEach(contexts, id: \.self) { Text($0).tag($0) }
                        }
                        Text("Puoi sempre cambiarlo progetto per progetto da Aree di lavoro.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var areas: some View {
        VStack(alignment: .leading, spacing: 14) {
            if contexts.isEmpty {
                note("Non hai ancora scelto nessun contesto: le aree si creano dentro un contesto. Torna indietro per aggiungerne uno, oppure chiudi e crea le aree più tardi.", symbol: "info.circle.fill", tint: .secondary)
            }
            ForEach(contexts, id: \.self) { context in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            IconTile(symbol: Theme.symbol(forContext: context), tint: Theme.color(forContext: context), size: 28)
                            Text(context).font(.headline)
                        }
                        ForEach(createdAreas[context] ?? [], id: \.self) { path in
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                        }
                        HStack(spacing: 8) {
                            TextField("Nome dell'area (es. server, grafica, contabilità)", text: Binding(get: { areaNames[context] ?? "" }, set: { areaNames[context] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { createArea(in: context) }
                            Button("Crea") { createArea(in: context) }
                                .disabled((areaNames[context] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .controlSize(.large)
                    }
                }
            }
            Card {
                Toggle(isOn: $autoDescriptions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Descrivi automaticamente le chat").font(.headline)
                        Text("Claude (Haiku) scrive una o due frasi su cosa contiene ogni chat. Consumo minimo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var canContinue: Bool {
        switch step {
        case .contexts: return !contexts.isEmpty
        case .folders: return !chatRoot.isEmpty
        default: return true
        }
    }

    // MARK: - Actions

    private func load() {
        let config = store.config
        isFirstRun = config.onboardingDone != true
        chatRoot = config.chatRoot
        projectsRoot = config.projectsRoot
        contexts = config.contexts
        defaultProjectContext = config.defaultProjectContext ?? ""
        autoDescriptions = store.autoDescriptions
    }

    private func next() {
        if step == .contexts { saveConfig() }
        step = Step(rawValue: step.rawValue + 1) ?? .areas
    }

    /// Closes the setup without changing the saved choices (accounts already created stay).
    private func skip() {
        store.config.onboardingDone = true
        store.config.save()
        onFinish()
    }

    private func addAccount() {
        accountProblem = nil
        do {
            let dir = try AccountSetup.create(name: newAccountName, shareHistory: shareHistory)
            newAccountName = ""
            store.login(configDir: dir)
            refresh += 1
        } catch {
            accountProblem = error.localizedDescription
        }
    }

    private func addContext() {
        let name = newContext.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, !contexts.contains(name) else { return }
        contexts.append(name)
        newContext = ""
    }

    private func saveConfig() {
        store.config.chatRoot = chatRoot
        store.config.projectsRoot = useProjects ? projectsRoot : ClaudePaths.home.appendingPathComponent(".ai-switchboard-no-projects").path
        store.config.contexts = contexts
        store.config.defaultProjectContext = defaultProjectContext.isEmpty ? nil : defaultProjectContext
        store.config.save()
        Workspaces.ensureRoots(store.config)
        store.reloadFolders()
    }

    private func createArea(in context: String) {
        guard let path = store.createArea(named: areaNames[context] ?? "", context: context) else { return }
        createdAreas[context, default: []].append(path)
        areaNames[context] = ""
    }

    private func finish() {
        saveConfig()
        store.autoDescriptions = autoDescriptions
        store.config.onboardingDone = true
        store.config.save()
        store.reloadAll()
        onFinish()
    }
}
