import SwiftUI
import AppKit

struct MemoryView: View {
    @ObservedObject var store: DeckStore

    @State private var selection: MemoryFile?
    @State private var text = ""
    @State private var original = ""
    @State private var trashTarget: MemoryFile?

    private var grouped: [(project: String, files: [MemoryFile])] {
        Dictionary(grouping: store.memoryFiles, by: \.projectDir)
            .map { ($0.key, $0.value) }
            .sorted { projectLabel($0.project) < projectLabel($1.project) }
    }

    private var isDirty: Bool { text != original }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(grouped, id: \.project) { group in
                    Section(projectLabel(group.project)) {
                        ForEach(group.files) { file in
                            HStack(spacing: 8) {
                                Image(systemName: file.isIndex ? "list.bullet.rectangle.fill" : "doc.text")
                                    .foregroundStyle(file.isIndex ? Theme.coral : .secondary)
                                Text(file.url.deletingPathExtension().lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                Text(relative(file.modifiedAt))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .tag(file)
                            .contextMenu {
                                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                Button("Sposta nel Cestino", role: .destructive) { trashTarget = file }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

            editor
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .navigationTitle("Memoria")
        .toolbar {
            ToolbarItem {
                Button {
                    store.reloadMemory()
                } label: {
                    Label("Aggiorna", systemImage: "arrow.clockwise")
                }
            }
        }
        .onChange(of: selection) { _, file in load(file) }
        .alert(
            "Spostare “\(trashTarget?.url.lastPathComponent ?? "")” nel Cestino?",
            isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })
        ) {
            Button("Sposta nel Cestino", role: .destructive) {
                if let file = trashTarget {
                    store.trashMemory(file)
                    if selection == file { selection = nil }
                }
                trashTarget = nil
            }
            Button("Annulla", role: .cancel) { trashTarget = nil }
        } message: {
            Text("Ricordati di togliere anche la riga corrispondente da MEMORY.md.")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let file = selection {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    IconTile(symbol: file.isIndex ? "list.bullet.rectangle.fill" : "brain.head.profile", tint: .purple, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.url.lastPathComponent)
                            .font(.headline)
                        Text(projectLabel(file.projectDir))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDirty {
                        Button("Annulla modifiche") { text = original }
                            .secondaryButton()
                    }
                    Button {
                        save(file)
                    } label: {
                        Label("Salva", systemImage: "checkmark")
                    }
                    .prominentButton()
                    .tint(.purple)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
                }
                .padding(14)
                Divider()
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            EmptyStateView(
                symbol: "brain.head.profile",
                title: "Memoria di Claude",
                message: "Le note che Claude ricorda tra una sessione e l'altra, per progetto. Sono condivise tra gli account."
            )
        }
    }

    private func load(_ file: MemoryFile?) {
        guard let file else { return }
        original = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        text = original
    }

    private func save(_ file: MemoryFile) {
        do {
            try text.write(to: file.url, atomically: true, encoding: .utf8)
            original = text
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}
