import AppKit

/// Updates from GitHub Releases: the latest release's `AISwitchboard.zip` replaces the running
/// app, which then relaunches. The download is checked (same bundle id, expected version)
/// before anything is replaced; the previous version goes to the Trash.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "friconelli/ai-switchboard"
    static let assetName = "AISwitchboard.zip"

    struct Release: Equatable {
        let version: String
        let notes: String
        let downloadURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var latest: Release?
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates")
            objectWillChange.send()
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var updateAvailable: Bool {
        latest.map { Self.isNewer($0.version, than: currentVersion) } ?? false
    }

    /// At launch, at most every six hours.
    func checkIfDue() {
        guard autoCheck else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
        Task { await check() }
    }

    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                state = .upToDate
                return
            }
            struct Payload: Decodable {
                struct Asset: Decodable { let name: String; let browser_download_url: URL }
                let tag_name: String
                let body: String?
                let html_url: URL
                let assets: [Asset]
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard let asset = payload.assets.first(where: { $0.name == Self.assetName }) else {
                throw ChatOperationError.io("La release \(payload.tag_name) non contiene \(Self.assetName)")
            }
            latest = Release(
                version: payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                notes: payload.body ?? "",
                downloadURL: asset.browser_download_url,
                pageURL: payload.html_url
            )
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck")
            state = updateAvailable ? .available : .upToDate
        } catch {
            state = .failed("Controllo non riuscito: \(error.localizedDescription)")
        }
    }

    func install() async {
        guard let latest, updateAvailable else { return }
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else {
            state = .failed("L'app non è in un pacchetto .app: aggiornamento non possibile da qui.")
            return
        }

        state = .downloading
        do {
            let (downloaded, _) = try await URLSession.shared.download(from: latest.downloadURL)
            state = .installing
            let work = fm.temporaryDirectory.appendingPathComponent("AISwitchboard-update-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent(Self.assetName)
            try fm.moveItem(at: downloaded, to: zip)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

            guard let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
                  let bundle = Bundle(url: app),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == latest.version else {
                throw ChatOperationError.io("Il pacchetto scaricato non è una versione valida di AI Switchboard.")
            }
            // Downloaded by the app itself it has no quarantine flag, but clear it in case.
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            _ = try fm.replaceItemAt(current, withItemAt: app, backupItemName: nil, options: [])
            try? fm.removeItem(at: work)
            relaunch(current)
        } catch {
            state = .failed("Aggiornamento non riuscito: \(error.localizedDescription)")
        }
    }

    private func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ChatOperationError.io("\(URL(fileURLWithPath: tool).lastPathComponent) non riuscito")
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
