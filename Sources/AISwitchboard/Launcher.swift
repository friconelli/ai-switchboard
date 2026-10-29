import AppKit

/// Opens a command in a new Warp tab, or Terminal as fallback.
///
/// Warp (2026) no longer runs launch configurations from a URL, so the tab is opened at the
/// working directory and the command is pasted into it. Pasting needs the Accessibility
/// permission; without it the command is left on the clipboard.
/// Opens Claude in a new Warp tab (or Terminal when Warp is missing).
///
/// Warp (2026) can't run a command from a URL and `warpctrl` can only type into the input,
/// so the command is queued for `ShellHook`, which runs it at the new tab's first prompt.
/// Without the hook nothing is opened: the caller asks the user to enable it first.
enum Launcher {
    enum Outcome {
        case started
        case needsDirectLaunch(command: String, directory: String)
    }

    private static let warpBundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp"]

    private static var warpURL: URL? {
        warpBundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var terminalName: String { warpURL != nil ? "Warp" : "Terminale" }

    @discardableResult
    static func resume(_ session: ChatSession, account: ClaudeAccount, model: String? = nil, prompt: String? = nil) -> Outcome {
        let command = "\(account.commandPrefix)\(model.map { " --model \($0)" } ?? "") --resume \(session.id)"
        return run(command + (prompt.map { " " + shellQuote($0) } ?? ""), in: session.workingDirectory)
    }

    @discardableResult
    static func newChat(in directory: String, account: ClaudeAccount, model: String? = nil, prompt: String? = nil) -> Outcome {
        run(account.commandPrefix + (model.map { " --model \($0)" } ?? "") + (prompt.map { " " + shellQuote($0) } ?? ""), in: directory)
    }

    /// Single-quoted for zsh.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func run(_ command: String, in directory: String) -> Outcome {
        guard warpURL != nil else {
            openInTerminal(command, directory: directory)
            return .started
        }
        guard ShellHook.isInstalled, ShellHook.queue(command, for: directory) else {
            return .needsDirectLaunch(command: command, directory: directory)
        }
        openTab(at: directory)
        return .started
    }

    /// One-off fallback: opens the tab and leaves the command on the clipboard.
    static func openTabCopyingCommand(_ command: String, directory: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        openTab(at: directory)
    }

    private static func openTab(at directory: String) {
        guard let warpURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: warpURL, configuration: configuration)
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

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A small zsh hook in `~/.zshrc`: at the first prompt of a new shell it runs the command
/// AI Switchboard queued for that folder (if fresher than 30 seconds), so Warp opens the
/// chat directly without simulated keystrokes or the Accessibility permission.
enum ShellHook {
    static let startMarker = "# >>> AI Switchboard >>>"
    static let endMarker = "# <<< AI Switchboard <<<"

    private static var zshrc: URL { ClaudePaths.home.appendingPathComponent(".zshrc") }
    private static var queueDir: URL { ClaudePaths.home.appendingPathComponent(".ai-switchboard/launch") }
    private static var backup: URL { ClaudePaths.home.appendingPathComponent(".ai-switchboard/zshrc.backup") }

    static let block = """
    \(startMarker)
    # Runs a command queued by AI Switchboard when a new tab opens in its folder (once per shell).
    _ai_switchboard_launch() {
      precmd_functions=(${precmd_functions:#_ai_switchboard_launch})
      local dir="$HOME/.ai-switchboard/launch" f claimed now=$(date +%s)
      [[ -d $dir ]] || return 0
      for f in "$dir"/*.zsh(N.Om); do
        if (( now - $(stat -f %m "$f") > 30 )); then rm -f "$f"; continue; fi
        [[ "$(head -1 "$f")" == "# cwd: ${PWD:A}" ]] || continue
        claimed="$f.$$"
        mv "$f" "$claimed" 2>/dev/null || continue
        source "$claimed"
        rm -f "$claimed"
        return 0
      done
    }
    precmd_functions+=(_ai_switchboard_launch)
    \(endMarker)
    """

    static var isInstalled: Bool {
        (try? String(contentsOf: zshrc, encoding: .utf8))?.contains(startMarker) ?? false
    }

    static func install() throws {
        guard !isInstalled else { return }
        let current = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try current.write(to: backup, atomically: true, encoding: .utf8)
        let separator = current.isEmpty || current.hasSuffix("\n") ? "\n" : "\n\n"
        try (current + separator + block + "\n").write(to: zshrc, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        guard let current = try? String(contentsOf: zshrc, encoding: .utf8),
              let start = current.range(of: startMarker),
              let end = current.range(of: endMarker, range: start.upperBound..<current.endIndex) else { return }
        var lineEnd = end.upperBound
        if lineEnd < current.endIndex, current[lineEnd] == "\n" { lineEnd = current.index(after: lineEnd) }
        var updated = current
        updated.removeSubrange(start.lowerBound..<lineEnd)
        while updated.hasSuffix("\n\n") { updated.removeLast() }
        try updated.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    /// Writes `<queue>/<uuid>.zsh` with the folder on the first line and the command after it.
    static func queue(_ command: String, for directory: String) -> Bool {
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        let file = queueDir.appendingPathComponent("\(UUID().uuidString).zsh")
        let script = "# cwd: \(resolved)\n\(command)\n"
        do {
            try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
