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
