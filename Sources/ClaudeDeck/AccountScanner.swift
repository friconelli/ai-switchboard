import Foundation
import Darwin

enum AccountScanner {
    /// `~/.claude` (default) plus every `~/.claude-*` directory holding a `.claude.json`.
    static func accounts() -> [ClaudeAccount] {
        let fm = FileManager.default
        let home = ClaudePaths.home
        var result: [ClaudeAccount] = []

        let defaultDir = home.appendingPathComponent(".claude")
        if fm.fileExists(atPath: home.appendingPathComponent(".claude.json").path) {
            result.append(load(
                name: "predefinito",
                configDir: defaultDir,
                stateFile: home.appendingPathComponent(".claude.json"),
                isDefault: true
            ))
        }

        let entries = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        for entry in entries.sorted() where entry.hasPrefix(".claude-") {
            let dir = home.appendingPathComponent(entry)
            let state = dir.appendingPathComponent(".claude.json")
            guard fm.fileExists(atPath: state.path) else { continue }
            result.append(load(
                name: String(entry.dropFirst(".claude-".count)),
                configDir: dir,
                stateFile: state,
                isDefault: false
            ))
        }

        // Named accounts first, default last.
        return result.sorted { ($0.isDefault ? 1 : 0, $0.name) < ($1.isDefault ? 1 : 0, $1.name) }
    }

    private static func load(name: String, configDir: URL, stateFile: URL, isDefault: Bool) -> ClaudeAccount {
        var account = ClaudeAccount(id: configDir.path, name: name, configDir: configDir, isDefault: isDefault)

        if let json = readJSON(stateFile), let oauth = json["oauthAccount"] as? [String: Any] {
            account.email = oauth["emailAddress"] as? String
            account.organization = oauth["organizationName"] as? String
            account.plan = oauth["organizationType"] as? String
        }

        if let settings = readJSON(configDir.appendingPathComponent("settings.json")) {
            account.model = settings["model"] as? String
            if let plugins = settings["enabledPlugins"] as? [String: Bool] {
                account.pluginCount = plugins.values.filter { $0 }.count
            }
        }

        let (last, today) = historyStats(configDir.appendingPathComponent("history.jsonl"))
        account.lastActivity = last
        account.promptsToday = today

        let projectsLink = configDir.appendingPathComponent("projects")
        account.sharesHistory = isDefault
            || projectsLink.resolvingSymlinksInPath().path == ClaudePaths.projects.path
        return account
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Last prompt date and number of prompts sent today, from `history.jsonl`.
    private static func historyStats(_ url: URL) -> (Date?, Int) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, 0) }
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        var last: Double = 0
        var today = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = json["timestamp"] as? Double else { continue }
            last = max(last, ts)
            if ts >= startOfDay { today += 1 }
        }
        return (last > 0 ? Date(timeIntervalSince1970: last / 1000) : nil, today)
    }

    /// Session IDs each account has sent prompts to, from `history.jsonl`.
    static func sessionAccounts(_ accounts: [ClaudeAccount]) -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for account in accounts {
            let url = account.configDir.appendingPathComponent("history.jsonl")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let range = line.range(of: "\"sessionId\":\"") else { continue }
                let rest = line[range.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { continue }
                map[String(rest[..<end]), default: []].insert(account.id)
            }
        }
        return map
    }

    // MARK: - Running sessions

    static func activeSessions(_ accounts: [ClaudeAccount]) -> [ActiveSession] {
        let fm = FileManager.default
        var result: [ActiveSession] = []
        for account in accounts {
            let dir = account.configDir.appendingPathComponent("sessions")
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let json = readJSON(file),
                      let pid = (json["pid"] as? NSNumber)?.int32Value,
                      isAlive(pid),
                      let sessionId = json["sessionId"] as? String else { continue }
                result.append(ActiveSession(
                    pid: pid,
                    sessionId: sessionId,
                    cwd: json["cwd"] as? String ?? "",
                    name: json["name"] as? String,
                    status: json["status"] as? String,
                    kind: json["kind"] as? String,
                    startedAt: millis(json["startedAt"]),
                    updatedAt: millis(json["updatedAt"]),
                    accountID: account.id,
                    accountName: account.name
                ))
            }
        }
        return result.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    private static func millis(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
