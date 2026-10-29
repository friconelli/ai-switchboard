import SwiftUI
import AppKit

// MARK: - Areas and projects

struct WorkspacesView: View {
    @ObservedObject var store: DeckStore
    let onShowChats: (ChatScope) -> Void

    @State private var newAreaContext: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    symbol: "folder.fill",
                    tint: .orange,
                    title: "Aree di lavoro",
                    subtitle: "Le chat che non riguardano un repo partono da un'area in “\(store.config.chatRoot.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))”. I progetti di codice restano in ~/projects e hanno un contesto assegnato."
                ) {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: store.config.chatRoot))
                    } label: {
                        Label("Apri cartella", systemImage: "folder")
                    }
                    .secondaryButton()
                }

                ForEach(store.config.contexts, id: \.self) { context in
                    contextSection(context)
                }

                projectsSection
            }
            .padding(24)
        }
        .navigationTitle("Aree di lavoro")
        .toolbar {
            ToolbarItem {
                Button {
                    store.reloadFolders()
                } label: {
                    Label("Aggiorna", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: Binding(get: { newAreaContext.map(IdentifiedString.init) }, set: { newAreaContext = $0?.value })) { item in
            NewAreaSheet(store: store, context: item.value) { _ in }
        }
    }

    private func contextSection(_ context: String) -> some View {
        let areas = store.areas.filter { $0.context == context }
        let color = Theme.color(forContext: context)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: Theme.symbol(forContext: context), tint: color, size: 28)
                Text(context)
                    .font(.title3.bold())
                Button("\(store.chats.filter { store.context(for: $0) == context }.count) chat") {
                    onShowChats(.context(context))
                }
                .buttonStyle(.link)
                Spacer()
                Button {
                    newAreaContext = context
                } label: {
                    Label("Nuova area", systemImage: "plus")
                }
                .prominentButton()
                .tint(color)
            }

            if areas.isEmpty {
                Card {
                    Text("Nessuna area. Creane una per ogni attività (es. “server”, “grafica”, “film”) e fai partire da lì le chat.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(areas) { area in
                        FolderCard(store: store, folder: area, tint: color)
                    }
                }
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: "chevron.left.forwardslash.chevron.right", tint: .gray, size: 28)
                Text("Progetti di codice")
                    .font(.title3.bold())
                Text(store.config.projectsRoot.replacingOccurrences(of: ClaudePaths.home.path, with: "~"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Card(padding: 6) {
                LazyVStack(spacing: 0) {
                    ForEach(store.projects) { project in
                        ProjectRow(store: store, project: project)
                        if project != store.projects.last { Divider().padding(.leading, 12) }
                    }
                }
            }
        }
    }
}

private struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

private struct FolderCard: View {
    @ObservedObject var store: DeckStore
    let folder: WorkFolder
    let tint: Color

    var body: some View {
        let chats = store.chats(in: folder)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(tint)
                    Text(folder.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                }
                Text(chats.isEmpty ? "Nessuna chat" : "\(chats.count) chat · ultima \(relative(chats.map(\.modifiedAt).max()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    NewChatMenu(store: store, folder: folder.path)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: folder.path))
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Apri nel Finder")
                    .secondaryButton()
                }
            }
        }
    }
}

private struct ProjectRow: View {
    @ObservedObject var store: DeckStore
    let project: WorkFolder

    var body: some View {
        let chats = store.chats(in: project)
        HStack(spacing: 10) {
            Text(project.name)
                .lineLimit(1)
            if !chats.isEmpty {
                Text("\(chats.count) chat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { project.context ?? "" },
                set: { store.setContext($0.isEmpty ? nil : $0, forFolder: project.path) }
            )) {
                ForEach(store.config.contexts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            NewChatMenu(store: store, folder: project.path, compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct NewChatMenu: View {
    @ObservedObject var store: DeckStore
    let folder: String
    var compact = false

    var body: some View {
        Menu {
            ForEach(store.accounts) { account in
                Button(account.name) { store.newChat(in: folder, with: account) }
            }
        } label: {
            if compact {
                Image(systemName: "plus.bubble")
            } else {
                Label("Nuova chat", systemImage: "plus.bubble")
            }
        } primaryAction: {
            if let account = store.preferredAccount { store.newChat(in: folder, with: account) }
        }
        .menuStyle(.button)
        .secondaryButton()
        .fixedSize()
        .help("Nuova chat in \(Launcher.terminalName) (freccia per scegliere l'account)")
    }
}

// MARK: - Sheets

struct NewAreaSheet: View {
    @ObservedObject var store: DeckStore
    let context: String
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuova area in \(context)")
                .font(.title3.bold())
            TextField("Nome (es. server, grafica, film)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            Text("Crea la cartella con CLAUDE.md, risorse/ e output/ in \(store.config.contextRoot(context).replacingOccurrences(of: ClaudePaths.home.path, with: "~")).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Crea", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func create() {
        guard let path = store.createArea(named: name, context: context) else { return }
        onCreated(path)
        dismiss()
    }
}

/// Picks a destination folder: an area, a code project, a new area or any folder.
struct FolderPickerSheet: View {
    @ObservedObject var store: DeckStore
    let title: String
    let message: String
    var excluding: Set<String> = []
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var query = ""
    @State private var newAreaName = ""
    @State private var newAreaContext = ""

    private func matches(_ folder: WorkFolder) -> Bool {
        !excluding.contains(folder.path) && (query.isEmpty || folder.name.localizedCaseInsensitiveContains(query))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .lineLimit(2)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Cerca area o progetto", text: $query)
                .textFieldStyle(.roundedBorder)

            List(selection: $selection) {
                ForEach(store.config.contexts, id: \.self) { context in
                    Section("Aree · \(context)") {
                        ForEach(store.areas.filter { $0.context == context && matches($0) }) { area in
                            Label(area.name, systemImage: "folder.fill")
                                .foregroundStyle(Theme.color(forContext: context))
                                .tag(area.path)
                        }
                    }
                }
                Section("Progetti di codice") {
                    ForEach(store.projects.filter(matches)) { project in
                        HStack {
                            Label(project.name, systemImage: "chevron.left.forwardslash.chevron.right")
                            Spacer()
                            if let context = project.context {
                                Text(context)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(project.path)
                    }
                }
            }
            .frame(height: 300)

            HStack(spacing: 8) {
                Text("Oppure nuova area:")
                    .font(.callout)
                TextField("nome", text: $newAreaName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Picker("", selection: $newAreaContext) {
                    ForEach(store.config.contexts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Crea e scegli") {
                    if let path = store.createArea(named: newAreaName, context: newAreaContext) {
                        selection = path
                        newAreaName = ""
                    }
                }
                .disabled(newAreaName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Button("Altra cartella…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: store.config.chatRoot)
                    if panel.runModal() == .OK, let url = panel.url {
                        onPick(url.path)
                        dismiss()
                    }
                }
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sposta qui") {
                    if let selection { onPick(selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { newAreaContext = store.config.contexts.first ?? "" }
    }
}
