import AppKit
import ApplicationServices

/// Opens a command in a new Warp tab, or Terminal as fallback.
///
/// Warp (2026) no longer runs launch configurations from a URL, so the tab is opened at the
/// working directory and the command is pasted into it. Pasting needs the Accessibility
/// permission; without it the command is left on the clipboard.
enum Launcher {
    enum Outcome {
        case started
        case copiedToClipboard(String)
    }

    private static let warpBundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp"]

    private static var warpURL: URL? {
        warpBundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var terminalName: String { warpURL != nil ? "Warp" : "Terminale" }

    @discardableResult
    static func resume(_ session: ChatSession, account: ClaudeAccount) -> Outcome {
        run("\(account.commandPrefix) --resume \(session.id)", in: session.workingDirectory)
    }

    @discardableResult
    static func newChat(in directory: String, account: ClaudeAccount) -> Outcome {
        run(account.commandPrefix, in: directory)
    }

    static func run(_ command: String, in directory: String) -> Outcome {
        guard let warpURL else {
            openInTerminal(command, directory: directory)
            return .started
        }

        // Preferred path: queue the command for the zsh hook, which runs it in the new tab.
        if ShellHook.isInstalled, ShellHook.queue(command, for: directory) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: warpURL, configuration: configuration)
            return .started
        }

        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: warpURL, configuration: configuration) { _, _ in
            guard trusted else { return }
            // Give Warp time to create the tab and focus its input.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                pressKey(9, flags: .maskCommand) // ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pressKey(36) // Return
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        pasteboard.clearContents()
                        if let previous { pasteboard.setString(previous, forType: .string) }
                    }
                }
            }
        }
        return trusted ? .started : .copiedToClipboard(command)
    }

    private static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
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
