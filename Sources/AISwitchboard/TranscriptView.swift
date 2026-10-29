import SwiftUI
import AppKit

struct TranscriptView: View {
    @ObservedObject var store: DeckStore
    let chat: ChatSession
    let actions: ChatActions

    @State private var messages: [TranscriptMessage] = []
    @State private var truncated = false
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView("Caricamento conversazione…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                EmptyStateView(symbol: "text.bubble", title: "Conversazione vuota")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if truncated {
                                Label("Mostro solo gli ultimi \(messages.count) messaggi", systemImage: "ellipsis")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            ForEach(messages) { message in
                                MessageView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(20)
                    }
                    .onAppear {
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: chat.id) {
            isLoading = true
            let url = chat.fileURL
            let result = await Task.detached(priority: .userInitiated) { TranscriptReader.read(url) }.value
            messages = result.messages
            truncated = result.truncated
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chat.displayTitle)
                        .font(.title2.bold())
                        .lineLimit(2)
                    if let description = store.description(for: chat) {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Label(chat.workingDirectory.replacingOccurrences(of: ClaudePaths.home.path, with: "~"), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ContextBadge(context: store.context(for: chat))
                        ForEach(store.accounts(for: chat)) { account in
                            AccountBadge(account: account, compact: true)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text("\(chat.promptCount) messaggi tuoi")
                        Text(formatBytes(chat.sizeBytes))
                        if let started = chat.startedAt {
                            Text("iniziata \(started.formatted(date: .abbreviated, time: .shortened))")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                ResumeButton(store: store, chat: chat, large: true)
            }

            HStack(spacing: 8) {
                ToolButton(title: "Dividi", symbol: "scissors") { actions.split(chat) }
                    .help("Dividi in più chat, una per argomento")
                ToolButton(title: "Snellisci", symbol: "arrow.down.right.and.arrow.up.left") { actions.slim([chat]) }
                    .help("Togli dati tecnici, immagini e output temporanei")
                ToolButton(title: "Sposta", symbol: "folder.badge.gearshape") { actions.move([chat]) }
                    .help("Sposta in un'area di lavoro o in un progetto")
                ToolButton(title: "Rinomina", symbol: "pencil") { actions.rename(chat) }
                Menu {
                    Menu("Contesto") {
                        ForEach(store.config.contexts, id: \.self) { context in
                            Button(context) { store.setContext(context, for: [chat]) }
                        }
                        Divider()
                        Button("Automatico (dalla cartella)") { store.setContext(nil, for: [chat]) }
                    }
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([chat.fileURL]) }
                    Button("Copia ID sessione") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(chat.id, forType: .string)
                    }
                    Divider()
                    Button("Sposta nel Cestino…", role: .destructive) { actions.trash([chat]) }
                } label: {
                    Label("Altro", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .secondaryButton()
                .fixedSize()
                Spacer()
            }
            .controlSize(.small)

            ChatHealthView(store: store, chat: chat, actions: actions)
        }
        .padding(16)
    }
}

private struct MessageView: View {
    let message: TranscriptMessage

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.coral.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .foregroundStyle(Theme.coral)
                    .padding(.top, 2)
                Text(markdown(message.text))
                    .textSelection(.enabled)
                Spacer(minLength: 40)
            }
        case .command:
            Label(message.text, systemImage: "command")
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .tools(let tools):
            ToolGroupView(tools: tools)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct ToolGroupView: View {
    let tools: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(tools.count == 1 ? tools[0] : "\(tools.count) strumenti usati")
                        .lineLimit(1)
                    if tools.count > 1 {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded && tools.count > 1 {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    Text(tool)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.leading, 26)
    }
}
