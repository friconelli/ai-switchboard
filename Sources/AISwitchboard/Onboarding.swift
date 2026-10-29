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

/// First-run setup: accounts, folders, contexts and first work areas. Nothing is preset.
struct OnboardingView: View {
    @ObservedObject var store: DeckStore
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, accounts, folders, contexts, areas

        var title: String {
            switch self {
            case .welcome: return "Benvenuto"
            case .accounts: return "Account"
            case .folders: return "Cartelle"
            case .contexts: return "Contesti"
            case .areas: return "Aree"
            }
        }
    }

    @State private var step = Step.welcome
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
    @State private var createdAreas: [String] = []
    @State private var autoDescriptions = true
    @State private var refresh = 0

    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Text(item.title)
                        .font(.caption.weight(item == step ? .bold : .regular))
                        .foregroundStyle(item == step ? Theme.coral : (item.rawValue < step.rawValue ? .primary : .secondary))
                    if item != Step.allCases.last {
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 20, height: 1)
                    }
                }
            }
            .padding(.top, 18)

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
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if step != .welcome {
                    Button("Indietro") { step = Step(rawValue: step.rawValue - 1)! }
                }
                Spacer()
                if step == .areas {
                    Button("Inizia a usare l'app") { finish() }
                        .prominentButton()
                        .tint(Theme.coral)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .welcome ? "Configura" : "Avanti") { next() }
                        .prominentButton()
                        .tint(Theme.coral)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .onAppear(perform: load)
        .onReceive(poll) { _ in
            if step == .accounts { store.reloadAccounts(); refresh += 1 }
            // Screenshots: `-debugOnboardingAutoAdvance YES` walks through the steps by itself.
            if UserDefaults.standard.bool(forKey: "debugOnboardingAutoAdvance"), step != .areas { next() }
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconTile(symbol: "point.3.connected.trianglepath.dotted", tint: Theme.coral, size: 64)
            Text("AI Switchboard")
                .font(.largeTitle.bold())
            Text("Un posto solo per tutte le tue chat di Claude Code, anche con più account: cercale, riprendile, uniscile o dividile, tienile leggere e falle partire dalla cartella giusta.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                bullet("person.2", "Collega i tuoi account Claude")
                bullet("folder", "Scegli dove tenere le chat e i progetti")
                bullet("tag", "Dividi le chat in contesti tuoi (es. personale, lavoro)")
                bullet("square.grid.2x2", "Crea le prime aree di lavoro")
            }
            Text("Tutto resta sul tuo Mac: l'app legge e scrive solo le cartelle di Claude Code e quelle che scegli tu.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var accounts: some View {
        let _ = refresh
        let pending = AccountSetup.pending(known: store.accounts)
        return VStack(alignment: .leading, spacing: 14) {
            header("I tuoi account Claude", "Ogni account di Claude Code è una cartella di configurazione. Se usi un solo account basta quello predefinito; per averne altri (es. personale e lavoro) aggiungili qui.")

            if store.accounts.isEmpty && pending.isEmpty {
                Text("Non ho trovato Claude Code configurato su questo Mac. Installalo (claude.com/claude-code), poi aggiungi qui il tuo account.")
                    .foregroundStyle(.orange)
            }
            ForEach(store.accounts) { account in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.isDefault ? "Predefinito (~/.claude)" : account.name).font(.headline)
                        Text([account.email, account.planLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.email == nil {
                        Button("Accedi") { store.login(configDir: account.configDir) }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(pending.filter { item in !store.accounts.contains { $0.configDir.path == item.url.path } }) { item in
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.headline)
                        Text("In attesa del login nella finestra del terminale").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apri login") { store.login(configDir: item.url) }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Aggiungi un account").font(.headline)
                    HStack {
                        TextField("Nome breve (es. lavoro)", text: $newAccountName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addAccount)
                        Button("Aggiungi e accedi", action: addAccount)
                            .disabled(AccountSetup.slug(newAccountName).isEmpty)
                    }
                    Toggle("Condividi lo storico delle chat con gli altri account", isOn: $shareHistory)
                    Text("Crea ~/.claude-\(AccountSetup.slug(newAccountName).isEmpty ? "nome" : AccountSetup.slug(newAccountName)) e apre Claude nel terminale: fai il login con l'account che vuoi usare. Da terminale lo userai con CLAUDE_CONFIG_DIR=~/.claude-<nome> claude.")
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

    private var folders: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Dove stanno le cose", "Le chat che non riguardano un progetto di codice partono da “aree di lavoro” dentro una cartella dedicata, così i progetti restano puliti.")
            folderRow("Cartella delle chat", path: $chatRoot, help: "Qui l'app crea una sottocartella per contesto e, dentro, le aree di lavoro.")
            Toggle("Ho una cartella con i progetti di codice", isOn: $useProjects)
            if useProjects {
                folderRow("Cartella dei progetti", path: $projectsRoot, help: "Ogni sottocartella è un progetto: le chat partite da lì vengono riconosciute.")
            }
        }
    }

    private var contextsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Contesti", "Gruppi in cui dividere le chat, indipendenti dall'account usato. Ne serve almeno uno.")
            HStack {
                TextField("Nome del contesto", text: $newContext)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addContext)
                Button("Aggiungi", action: addContext)
                    .disabled(newContext.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 6) {
                Text("Suggeriti:").font(.caption).foregroundStyle(.secondary)
                ForEach(["Personale", "Lavoro", "Clienti", "Studio"].filter { !contexts.contains($0) }, id: \.self) { name in
                    Button(name) { contexts.append(name) }
                        .controlSize(.small)
                }
            }
            ForEach(contexts, id: \.self) { context in
                HStack {
                    ContextBadge(context: context)
                    Spacer()
                    Button { contexts.removeAll { $0 == context } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if useProjects && !contexts.isEmpty {
                Picker("Contesto dei progetti di codice", selection: $defaultProjectContext) {
                    Text("Nessuno (da assegnare)").tag("")
                    ForEach(contexts, id: \.self) { Text($0).tag($0) }
                }
                Text("Puoi sempre cambiarlo progetto per progetto da Aree di lavoro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var areas: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Prime aree di lavoro", "Un'area è una cartella da cui far partire le chat su un'attività (es. server, grafica, contabilità), con un CLAUDE.md e le cartelle risorse/ e output/. Puoi saltare questo passo e crearle dopo.")
            ForEach(contexts, id: \.self) { context in
                HStack {
                    ContextBadge(context: context)
                        .frame(width: 130, alignment: .leading)
                    TextField("Nome dell'area", text: Binding(get: { areaNames[context] ?? "" }, set: { areaNames[context] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { createArea(in: context) }
                    Button("Crea") { createArea(in: context) }
                        .disabled((areaNames[context] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(createdAreas, id: \.self) { path in
                Label(path.replacingOccurrences(of: ClaudePaths.home.path, with: "~"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Divider()
            Toggle("Descrivi automaticamente le chat con Claude (Haiku, consumo minimo)", isOn: $autoDescriptions)
        }
    }

    // MARK: - Pieces

    private func header(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.body)
    }

    private func folderRow(_ title: String, path: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            HStack {
                Text(path.wrappedValue.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                Button("Scegli…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: path.wrappedValue).deletingLastPathComponent()
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
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
        createdAreas.append(path)
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
