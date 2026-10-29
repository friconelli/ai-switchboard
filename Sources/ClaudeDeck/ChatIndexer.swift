import Foundation

/// Builds `ChatSession` metadata from transcript files without decoding every line:
/// lines are scanned with `memmem` and only the few interesting ones are parsed.
/// Results are cached on disk keyed by file size + modification date.
final class ChatIndexer {
    private struct CacheEntry: Codable {
        let size: Int64
        let modified: Date
        let session: ChatSession
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheURL = ClaudePaths.appSupport.appendingPathComponent("index-cache.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            cache = decoded
        }
    }

    func indexAll(progress: (Int, Int) -> Void) -> [ChatSession] {
        let fm = FileManager.default
        let root = ClaudePaths.projects
        let projectDirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []

        var files: [(URL, String)] = []
        for dir in projectDirs {
            let entries = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )) ?? []
            for file in entries where file.pathExtension == "jsonl" {
                files.append((file, dir.lastPathComponent))
            }
        }

        var sessions: [ChatSession] = []
        var fresh: [String: CacheEntry] = [:]
        for (index, (file, projectDir)) in files.enumerated() {
            progress(index, files.count)
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { continue }

            if let cached = cache[file.path], cached.size == Int64(size), cached.modified == modified {
                sessions.append(cached.session)
                fresh[file.path] = cached
                continue
            }
            guard let session = Self.index(file: file, projectDir: projectDir, size: Int64(size), modified: modified) else { continue }
            sessions.append(session)
            fresh[file.path] = CacheEntry(size: Int64(size), modified: modified, session: session)
        }

        cache = fresh
        if let data = try? JSONEncoder().encode(fresh) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return sessions.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Single file

    private static let customTitleNeedle = Array(#"{"type":"custom-title""#.utf8)
    private static let aiTitleNeedle = Array(#"{"type":"ai-title""#.utf8)
    private static let cwdNeedle = Array(#""cwd":""#.utf8)
    private static let timestampNeedle = Array(#""timestamp":""#.utf8)
    private static let userTypeNeedle = Array(#""type":"user""#.utf8)
    private static let promptNeedle = Array(#""message":{"role":"user","content":""#.utf8)
    private static let metaNeedle = Array(#""isMeta":true"#.utf8)
    private static let sidechainNeedle = Array(#""isSidechain":true"#.utf8)

    static func index(file: URL, projectDir: String, size: Int64, modified: Date) -> ChatSession? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        var session = ChatSession(
            id: file.deletingPathExtension().lastPathComponent,
            fileURL: file,
            projectDir: projectDir,
            modifiedAt: modified,
            sizeBytes: size
        )
        var aiTitle: String?
        var customTitle: String?

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            forEachLine(base: base, count: raw.count) { line, length in
                if hasPrefix(line, length, customTitleNeedle) {
                    customTitle = decode(line, length)?["customTitle"] as? String
                    return
                }
                if hasPrefix(line, length, aiTitleNeedle) {
                    aiTitle = decode(line, length)?["aiTitle"] as? String
                    return
                }
                if session.cwd == nil, let cwd = stringValue(after: cwdNeedle, in: line, length) {
                    session.cwd = cwd
                }
                if session.startedAt == nil, let ts = stringValue(after: timestampNeedle, in: line, length) {
                    session.startedAt = isoFormatter.date(from: ts)
                }
                guard contains(line, length, userTypeNeedle),
                      contains(line, length, promptNeedle),
                      !contains(line, length, metaNeedle),
                      !contains(line, length, sidechainNeedle) else { return }
                session.promptCount += 1
                if session.firstPrompt == nil,
                   let message = decode(line, length)?["message"] as? [String: Any],
                   let content = message["content"] as? String,
                   !content.hasPrefix("<") {
                    session.firstPrompt = String(content.prefix(300))
                        .replacingOccurrences(of: "\n", with: " ")
                }
            }
        }

        session.title = customTitle ?? aiTitle
        session.isCustomTitle = customTitle != nil
        return session
    }

    // MARK: - Byte helpers

    static func forEachLine(base: UnsafeRawPointer, count: Int, _ body: (UnsafeRawPointer, Int) -> Void) {
        var start = 0
        while start < count {
            let remaining = count - start
            let lineStart = base + start
            let end: Int
            if let newline = memchr(lineStart, 0x0A, remaining) {
                end = start + (UnsafeRawPointer(newline) - lineStart)
            } else {
                end = count
            }
            if end > start { body(lineStart, end - start) }
            start = end + 1
        }
    }

    static func contains(_ line: UnsafeRawPointer, _ length: Int, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { memmem(line, length, $0.baseAddress, needle.count) != nil }
    }

    private static func hasPrefix(_ line: UnsafeRawPointer, _ length: Int, _ needle: [UInt8]) -> Bool {
        guard length >= needle.count else { return false }
        return needle.withUnsafeBytes { memcmp(line, $0.baseAddress, needle.count) == 0 }
    }

    /// Value of the first `"key":"value"` occurrence (no unescaping beyond `\"` and `\\`).
    private static func stringValue(after needle: [UInt8], in line: UnsafeRawPointer, _ length: Int) -> String? {
        guard let match = needle.withUnsafeBytes({ memmem(line, length, $0.baseAddress, needle.count) }) else { return nil }
        let valueStart = UnsafeRawPointer(match) + needle.count
        let available = length - (valueStart - line)
        let bytes = valueStart.assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        var i = 0
        while i < available {
            let byte = bytes[i]
            if byte == UInt8(ascii: "\\"), i + 1 < available {
                out.append(bytes[i + 1])
                i += 2
                continue
            }
            if byte == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
            out.append(byte)
            i += 1
        }
        return nil
    }

    private static func decode(_ line: UnsafeRawPointer, _ length: Int) -> [String: Any]? {
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line), count: length, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
