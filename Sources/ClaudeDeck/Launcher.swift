import AppKit

/// Opens a command in a new Warp window (via a launch configuration), or Terminal as fallback.
enum Launcher {
    private static let warpBundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp"]

    static var warpInstalled: Bool {
        warpBundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    static var terminalName: String { warpInstalled ? "Warp" : "Terminale" }

    static func resume(_ session: ChatSession, account: ClaudeAccount) {
        run(
            "\(account.commandPrefix) --resume \(session.id)",
            in: session.workingDirectory,
            title: "\(account.name) · \(session.displayTitle.prefix(40))"
        )
    }

    static func newChat(in directory: String, account: ClaudeAccount) {
        run(account.commandPrefix, in: directory, title: "\(account.name) · \(URL(fileURLWithPath: directory).lastPathComponent)")
    }

    static func run(_ command: String, in directory: String, title: String) {
        if warpInstalled {
            openInWarp(command, directory: directory, title: title)
        } else {
            openInTerminal(command, directory: directory)
        }
    }

    private static func openInWarp(_ command: String, directory: String, title: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".warp/launch_configurations")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("claude-deck.yaml")
        let yaml = """
        ---
        name: Claude Deck
        windows:
          - tabs:
              - title: \(yamlQuoted(title))
                layout:
                  cwd: \(yamlQuoted(directory))
                  commands:
                    - exec: \(yamlQuoted(command))
        """
        do {
            try yaml.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            openInTerminal(command, directory: directory)
            return
        }
        if let url = URL(string: "warp://launch/claude-deck.yaml") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func openInTerminal(_ command: String, directory: String) {
        let shell = "cd \(shellQuoted(directory)) && \(command)"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private static func yamlQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
