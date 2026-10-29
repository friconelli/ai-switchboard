import Foundation

/// Moves a chat to another working directory so `/resume` finds it there.
///
/// The transcript is rewritten line by line as text (nothing else changes): the chat's
/// original `"cwd"` becomes the new folder and references to its side folder (tool results,
/// subagents) are updated, then file and side folder go to `~/.claude/projects/<encoded>/`.
/// The rewritten copy is checked before the original is moved to the Trash.
enum ChatMover {
    static func move(_ chat: ChatSession, to folder: String) throws -> URL {
        let fm = FileManager.default
        let oldCwd = chat.workingDirectory
        guard oldCwd != folder else { return chat.fileURL }

        let targetDir = ClaudePaths.projects.appendingPathComponent(Workspaces.encodedName(for: folder))
        let targetFile = targetDir.appendingPathComponent("\(chat.id).jsonl")
        let targetSide = targetDir.appendingPathComponent(chat.id)
        guard !fm.fileExists(atPath: targetFile.path) else {
            throw ChatOperationError.io("Nella destinazione esiste già una chat con lo stesso ID")
        }
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let oldCwdField = "\"cwd\":" + jsonString(oldCwd)
        let newCwdField = "\"cwd\":" + jsonString(folder)
        let sideAliases = MergeEngine.sideDirPaths(of: chat)

        let source = try Data(contentsOf: chat.fileURL)
        var output = Data(capacity: source.count)
        var sourceLines = 0
        var movedCwd = 0
        for line in source.split(separator: 0x0A, omittingEmptySubsequences: true) {
            sourceLines += 1
            var text = String(decoding: line, as: UTF8.self)
            if text.contains(oldCwdField) {
                text = text.replacingOccurrences(of: oldCwdField, with: newCwdField)
                movedCwd += 1
            }
            if text.contains(chat.id) {
                for alias in sideAliases where text.contains(alias) {
                    text = text.replacingOccurrences(of: alias, with: targetSide.path)
                }
            }
            output.append(Data(text.utf8))
            output.append(0x0A)
        }

        // Verify: same number of lines, all valid JSON, no line left in the old folder.
        let temp = targetDir.appendingPathComponent(".\(chat.id).jsonl.partial")
        try output.write(to: temp)
        let written = output.split(separator: 0x0A, omittingEmptySubsequences: true)
        let valid = written.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0))) != nil }
        let leftover = written.contains { String(decoding: $0, as: UTF8.self).contains(oldCwdField) }
        guard written.count == sourceLines, valid, !leftover, movedCwd > 0 || chat.cwd == nil else {
            try? fm.removeItem(at: temp)
            throw ChatOperationError.io("Verifica fallita durante lo spostamento di “\(chat.displayTitle)”: la chat non è stata toccata.")
        }

        let oldSide = chat.fileURL.deletingPathExtension()
        if fm.fileExists(atPath: oldSide.path) {
            try fm.moveItem(at: oldSide, to: targetSide)
        }
        try fm.moveItem(at: temp, to: targetFile)
        try fm.trashItem(at: chat.fileURL, resultingItemURL: nil)
        return targetFile
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

enum MemoryMover {
    /// Moves a memory file to another folder's memory and keeps both `MEMORY.md` indexes in sync.
    static func move(_ file: MemoryFile, toFolder folder: String) throws {
        let fm = FileManager.default
        let targetMemory = ClaudePaths.projects
            .appendingPathComponent(Workspaces.encodedName(for: folder))
            .appendingPathComponent("memory")
        let target = targetMemory.appendingPathComponent(file.url.lastPathComponent)
        guard target.path != file.url.path else { return }
        guard !fm.fileExists(atPath: target.path) else {
            throw ChatOperationError.io("Nella destinazione esiste già “\(file.url.lastPathComponent)”")
        }
        try fm.createDirectory(at: targetMemory, withIntermediateDirectories: true)
        try fm.moveItem(at: file.url, to: target)

        guard !file.isIndex else { return }
        let name = file.url.lastPathComponent
        let sourceIndex = file.url.deletingLastPathComponent().appendingPathComponent("MEMORY.md")
        var moved: [String] = []
        if var text = try? String(contentsOf: sourceIndex, encoding: .utf8) {
            var kept: [String] = []
            for line in text.components(separatedBy: "\n") {
                if line.contains("(\(name))") { moved.append(line) } else { kept.append(line) }
            }
            text = kept.joined(separator: "\n")
            try text.write(to: sourceIndex, atomically: true, encoding: .utf8)
        }
        let targetIndex = targetMemory.appendingPathComponent("MEMORY.md")
        var index = (try? String(contentsOf: targetIndex, encoding: .utf8)) ?? ""
        if moved.isEmpty {
            moved = ["- [\(file.url.deletingPathExtension().lastPathComponent)](\(name))"]
        }
        if !index.isEmpty && !index.hasSuffix("\n") { index += "\n" }
        index += moved.joined(separator: "\n") + "\n"
        try index.write(to: targetIndex, atomically: true, encoding: .utf8)
    }
}
