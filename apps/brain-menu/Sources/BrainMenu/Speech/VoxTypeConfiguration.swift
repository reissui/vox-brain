import Darwin
import Foundation

enum VoxTypeConfigurationWriteEvent: Equatable, Sendable {
    case beforeBackupReplacement
    case beforeConfigurationReplacement
    case beforeRollbackReplacement
}

enum VoxTypeConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfigurationPath
    case configurationMissing
    case configurationIsNotRegularFile
    case configurationTooLarge
    case invalidUTF8
    case invalidSelection
    case duplicateEngineKey
    case duplicateEngineSection(SpeechEngineID)
    case duplicateModelKey(SpeechEngineID)
    case duplicateAudioSection
    case duplicateMaximumDurationKey
    case duplicateOutputSection
    case duplicatePostProcessKey
    case duplicatePostProcessSection
    case duplicatePostProcessCommand
    case duplicatePostProcessTimeout
    case ambiguousPostProcessKey
    case postProcessConflict
    case invalidMaximumDuration
    case invalidPostProcessExecutable
    case unsafeBackup
    case backupWriteFailed
    case atomicWriteFailed
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfigurationPath:
            "The VoxType configuration path is not an absolute file path."
        case .configurationMissing:
            "VoxType's configuration file is missing. Open VoxType once, then try again."
        case .configurationIsNotRegularFile:
            "VoxType's configuration must be a regular file, not a link or directory."
        case .configurationTooLarge:
            "VoxType's configuration exceeds Brain's 1 MiB safety limit."
        case .invalidUTF8:
            "VoxType's configuration is not valid UTF-8."
        case .invalidSelection:
            "The requested engine and model are not a supported pair."
        case .duplicateEngineKey:
            "VoxType's configuration contains more than one top-level engine value."
        case .duplicateEngineSection(let engine):
            "VoxType's configuration contains more than one [\(engine.rawValue)] section."
        case .duplicateModelKey(let engine):
            "VoxType's [\(engine.rawValue)] section contains more than one model value."
        case .duplicateAudioSection:
            "VoxType's configuration contains more than one [audio] section."
        case .duplicateMaximumDurationKey:
            "VoxType's [audio] section contains more than one max_duration_secs value."
        case .duplicateOutputSection:
            "VoxType's configuration contains more than one [output] section."
        case .duplicatePostProcessKey:
            "VoxType's [output] section contains more than one post_process value."
        case .duplicatePostProcessSection:
            "VoxType's configuration contains more than one [output.post_process] section."
        case .duplicatePostProcessCommand:
            "VoxType's [output.post_process] section contains more than one command value."
        case .duplicatePostProcessTimeout:
            "VoxType's [output.post_process] section contains more than one timeout_ms value."
        case .ambiguousPostProcessKey:
            "VoxType's output.post_process setting is ambiguous."
        case .postProcessConflict:
            "VoxType already uses a different post-processor. Brain will not replace it."
        case .invalidMaximumDuration:
            "VoxType's maximum dictation duration must be between 60 and 3600 seconds."
        case .invalidPostProcessExecutable:
            "Brain's bundled dictation helper is missing or is not executable."
        case .unsafeBackup:
            "Brain refused to replace an unsafe VoxType configuration backup."
        case .backupWriteFailed:
            "Brain could not save the VoxType configuration backup."
        case .atomicWriteFailed:
            "Brain could not replace the VoxType configuration atomically."
        case .verificationFailed:
            "VoxType's saved engine and model did not match the requested selection."
        }
    }
}

struct VoxTypeConfigurationBackup: Equatable, Sendable {
    let data: Data
    let selection: SpeechEngineSelection?
}

protocol VoxTypeConfigurationEditing: Sendable {
    func apply(_ selection: SpeechEngineSelection) throws -> VoxTypeConfigurationBackup
    func rollback(to backup: VoxTypeConfigurationBackup) throws
}

protocol VoxTypeContinuousConfigurationEditing: Sendable {
    func configureMaximumDuration(seconds: Int) throws
}

/// A deliberately narrow TOML editor for VoxType's top-level `engine`, the
/// selected engine's `model`, and `[audio].max_duration_secs`. It never owns or
/// modifies VoxType's hotkey or output configuration.
final class VoxTypeConfigurationEditor: VoxTypeConfigurationEditing,
    VoxTypeContinuousConfigurationEditing,
    @unchecked Sendable {
    static let maximumConfigurationBytes = 1_048_576

    static func defaultConfigurationURL(
        homeDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let legacy = homeDirectoryURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("voxtype", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("voxtype", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    let configurationURL: URL
    let backupURL: URL

    private let fileManager: FileManager
    private let failureInjector: (@Sendable (VoxTypeConfigurationWriteEvent) throws -> Void)?
    private let lock = NSLock()

    init(
        configuredURL: URL? = nil,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        failureInjector: (@Sendable (VoxTypeConfigurationWriteEvent) throws -> Void)? = nil
    ) {
        let selected = configuredURL ?? Self.defaultConfigurationURL(
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )
        configurationURL = selected.standardizedFileURL
        backupURL = selected.standardizedFileURL.appendingPathExtension("brain-backup")
        self.fileManager = fileManager
        self.failureInjector = failureInjector
    }

    func apply(_ selection: SpeechEngineSelection) throws -> VoxTypeConfigurationBackup {
        try withLock {
            try validate(selection)
            let original = try readConfiguration()
            let document = try VoxTypeConfigurationDocument(data: original)
            let backup = VoxTypeConfigurationBackup(
                data: original,
                selection: try document.selection
            )
            let updated = try document.updating(selection)
            guard updated != original else { return backup }

            try replaceBackupAtomically(with: original)
            try replaceConfigurationAtomically(
                with: updated,
                event: .beforeConfigurationReplacement
            )
            do {
                guard try VoxTypeConfigurationDocument(data: readConfiguration()).selection
                    == selection else {
                    throw VoxTypeConfigurationError.verificationFailed
                }
            } catch {
                do {
                    try replaceConfigurationAtomically(
                        with: original,
                        event: .beforeRollbackReplacement
                    )
                    guard try readConfiguration() == original else {
                        throw VoxTypeConfigurationError.atomicWriteFailed
                    }
                } catch {
                    throw VoxTypeConfigurationError.atomicWriteFailed
                }
                throw VoxTypeConfigurationError.verificationFailed
            }
            return backup
        }
    }

    func rollback(to backup: VoxTypeConfigurationBackup) throws {
        try withLock {
            _ = try readConfiguration()
            guard backup.data.count <= Self.maximumConfigurationBytes,
                  String(data: backup.data, encoding: .utf8) != nil else {
                throw VoxTypeConfigurationError.unsafeBackup
            }
            try replaceConfigurationAtomically(
                with: backup.data,
                event: .beforeRollbackReplacement
            )
            guard try readConfiguration() == backup.data else {
                throw VoxTypeConfigurationError.verificationFailed
            }
        }
    }

    func configureMaximumDuration(seconds: Int) throws {
        try withLock {
            guard (60...3_600).contains(seconds) else {
                throw VoxTypeConfigurationError.invalidMaximumDuration
            }
            let original = try readConfiguration()
            let document = try VoxTypeConfigurationDocument(data: original)
            let updated = try document.updatingMaximumDuration(seconds)
            guard updated != original else { return }

            try replaceConfigurationAtomically(
                with: updated,
                event: .beforeConfigurationReplacement
            )
            do {
                let saved = try VoxTypeConfigurationDocument(data: readConfiguration())
                guard try saved.maximumDurationSeconds == seconds else {
                    throw VoxTypeConfigurationError.verificationFailed
                }
            } catch {
                do {
                    try replaceConfigurationAtomically(
                        with: original,
                        event: .beforeRollbackReplacement
                    )
                    guard try readConfiguration() == original else {
                        throw VoxTypeConfigurationError.atomicWriteFailed
                    }
                } catch {
                    throw VoxTypeConfigurationError.atomicWriteFailed
                }
                throw VoxTypeConfigurationError.verificationFailed
            }
        }
    }

    private func validate(_ selection: SpeechEngineSelection) throws {
        guard let model = SpeechEngineCatalog.model(id: selection.modelID),
              model.engine == selection.engine else {
            throw VoxTypeConfigurationError.invalidSelection
        }
        guard configurationURL.isFileURL, configurationURL.path.hasPrefix("/") else {
            throw VoxTypeConfigurationError.invalidConfigurationPath
        }
    }

    private func readConfiguration() throws -> Data {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            throw VoxTypeConfigurationError.configurationMissing
        }
        guard isRegularFileWithoutFollowingLink(configurationURL) else {
            throw VoxTypeConfigurationError.configurationIsNotRegularFile
        }
        let attributes = try fileManager.attributesOfItem(atPath: configurationURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumConfigurationBytes else {
            throw VoxTypeConfigurationError.configurationTooLarge
        }
        let data = try Data(contentsOf: configurationURL, options: [.mappedIfSafe])
        guard data.count <= Self.maximumConfigurationBytes else {
            throw VoxTypeConfigurationError.configurationTooLarge
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw VoxTypeConfigurationError.invalidUTF8
        }
        return data
    }

    private func replaceBackupAtomically(with data: Data) throws {
        if fileManager.fileExists(atPath: backupURL.path),
           !isRegularFileWithoutFollowingLink(backupURL) {
            throw VoxTypeConfigurationError.unsafeBackup
        }
        do {
            try failureInjector?(.beforeBackupReplacement)
            try replaceAtomically(data: data, destination: backupURL, permissions: 0o600)
        } catch let error as VoxTypeConfigurationError {
            if error == .unsafeBackup { throw error }
            throw VoxTypeConfigurationError.backupWriteFailed
        } catch {
            throw VoxTypeConfigurationError.backupWriteFailed
        }
    }

    private func replaceConfigurationAtomically(
        with data: Data,
        event: VoxTypeConfigurationWriteEvent
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: configurationURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        do {
            try failureInjector?(event)
            try replaceAtomically(
                data: data,
                destination: configurationURL,
                permissions: permissions & 0o777
            )
        } catch {
            throw VoxTypeConfigurationError.atomicWriteFailed
        }
    }

    private func replaceAtomically(data: Data, destination: URL, permissions: Int) throws {
        let directory = destination.deletingLastPathComponent()
        let staged = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).brain-tmp",
            isDirectory: false
        )
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions))
        guard descriptor >= 0 else { throw VoxTypeConfigurationError.atomicWriteFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            let result = staged.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    rename(source, target)
                }
            }
            guard result == 0 else { throw VoxTypeConfigurationError.atomicWriteFailed }
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    private func isRegularFileWithoutFollowingLink(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFREG
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private struct VoxTypeConfigurationDocument {
    private var lines: [VoxTypeSourceLine]
    private let preferredNewline: String
    private let endedWithNewline: Bool
    private let hasUTF8ByteOrderMark: Bool

    init(data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw VoxTypeConfigurationError.invalidUTF8
        }
        hasUTF8ByteOrderMark = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = hasUTF8ByteOrderMark && source.first == "\u{feff}"
            ? String(source.dropFirst())
            : source
        lines = VoxTypeSourceLine.split(body)
        preferredNewline = lines.lazy.map(\.terminator).first { !$0.isEmpty } ?? "\n"
        endedWithNewline = lines.last?.terminator.isEmpty == false
        _ = try scan()
    }

    var selection: SpeechEngineSelection? {
        get throws {
            let locations = try scan()
            guard let engineLine = locations.engineLines.first,
                  let engineValue = stringValue(at: engineLine),
                  let engine = SpeechEngineID(rawValue: engineValue),
                  let modelLine = locations.modelLines[engine]?.first,
                  let modelID = stringValue(at: modelLine),
                  SpeechEngineCatalog.model(id: modelID)?.engine == engine else {
                return nil
            }
            return SpeechEngineSelection(engine: engine, modelID: modelID)
        }
    }

    var maximumDurationSeconds: Int? {
        get throws {
            let locations = try scan()
            guard let line = locations.maximumDurationLines.first,
                  let assignment = VoxTypeParsedLine.assignment(lines[line].content) else {
                return nil
            }
            let value = lines[line].content[assignment.valueRange]
                .trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
    }

    func updating(_ selection: SpeechEngineSelection) throws -> Data {
        var copy = self
        try copy.update(selection)
        var data = copy.hasUTF8ByteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(contentsOf: copy.lines.map { $0.content + $0.terminator }.joined().utf8)
        return data
    }

    func updatingMaximumDuration(_ seconds: Int) throws -> Data {
        var copy = self
        try copy.updateMaximumDuration(seconds)
        var data = copy.hasUTF8ByteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(contentsOf: copy.lines.map { $0.content + $0.terminator }.joined().utf8)
        return data
    }

    private mutating func update(_ selection: SpeechEngineSelection) throws {
        var locations = try scan()
        if let engineLine = locations.engineLines.first {
            replaceValue(at: engineLine, with: quoted(selection.engine.rawValue))
        } else {
            insert(
                VoxTypeSourceLine(content: "engine = \(quoted(selection.engine.rawValue))", terminator: preferredNewline),
                at: locations.firstSectionLine ?? lines.count
            )
        }

        locations = try scan()
        if let modelLine = locations.modelLines[selection.engine]?.first {
            replaceValue(at: modelLine, with: quoted(selection.modelID))
        } else if let section = locations.engineSectionLines[selection.engine]?.first {
            let nextSection = locations.sectionLines.first { $0 > section } ?? lines.count
            insert(
                VoxTypeSourceLine(content: "model = \(quoted(selection.modelID))", terminator: preferredNewline),
                at: nextSection
            )
        } else {
            appendBlankLineIfNeeded()
            appendLine("[\(selection.engine.rawValue)]")
            appendLine("model = \(quoted(selection.modelID))")
        }

        if endedWithNewline {
            if !lines.isEmpty, lines[lines.count - 1].terminator.isEmpty {
                lines[lines.count - 1].terminator = preferredNewline
            }
        } else if !lines.isEmpty {
            lines[lines.count - 1].terminator = ""
        }
    }

    private mutating func updateMaximumDuration(_ seconds: Int) throws {
        let locations = try scan()
        if let line = locations.maximumDurationLines.first {
            replaceValue(at: line, with: String(seconds))
        } else if let section = locations.audioSectionLines.first {
            let nextSection = locations.sectionLines.first { $0 > section } ?? lines.count
            insert(
                VoxTypeSourceLine(
                    content: "max_duration_secs = \(seconds)",
                    terminator: preferredNewline
                ),
                at: nextSection
            )
        } else {
            appendBlankLineIfNeeded()
            appendLine("[audio]")
            appendLine("max_duration_secs = \(seconds)")
        }

        if endedWithNewline {
            if !lines.isEmpty, lines[lines.count - 1].terminator.isEmpty {
                lines[lines.count - 1].terminator = preferredNewline
            }
        } else if !lines.isEmpty {
            lines[lines.count - 1].terminator = ""
        }
    }

    private func scan() throws -> VoxTypeConfigurationLocations {
        var result = VoxTypeConfigurationLocations()
        var section: String?
        for (index, line) in lines.enumerated() {
            if let name = VoxTypeParsedLine.sectionName(line.content) {
                section = name
                result.sectionLines.append(index)
                if let engine = SpeechEngineID(rawValue: name) {
                    result.engineSectionLines[engine, default: []].append(index)
                }
                if name == "audio" { result.audioSectionLines.append(index) }
                if name == "output" { result.outputSectionLines.append(index) }
                if name == "output.post_process" {
                    result.postProcessSectionLines.append(index)
                }
                continue
            }
            if section == nil,
               VoxTypeParsedLine.rawAssignmentKey(line.content) == "output.post_process" {
                result.ambiguousPostProcessLines.append(index)
            }
            guard let assignment = VoxTypeParsedLine.assignment(line.content) else { continue }
            if section == nil, assignment.key == "engine" {
                result.engineLines.append(index)
            } else if assignment.key == "model", let section,
                      let engine = SpeechEngineID(rawValue: section) {
                result.modelLines[engine, default: []].append(index)
            } else if section == "audio", assignment.key == "max_duration_secs" {
                result.maximumDurationLines.append(index)
            } else if section == "output", assignment.key == "post_process" {
                result.legacyPostProcessLines.append(index)
            } else if section == "output.post_process", assignment.key == "command" {
                result.postProcessCommandLines.append(index)
            } else if section == "output.post_process", assignment.key == "timeout_ms" {
                result.postProcessTimeoutLines.append(index)
            }
        }

        guard result.engineLines.count <= 1 else {
            throw VoxTypeConfigurationError.duplicateEngineKey
        }
        for engine in SpeechEngineID.allCases {
            guard result.engineSectionLines[engine, default: []].count <= 1 else {
                throw VoxTypeConfigurationError.duplicateEngineSection(engine)
            }
            guard result.modelLines[engine, default: []].count <= 1 else {
                throw VoxTypeConfigurationError.duplicateModelKey(engine)
            }
        }
        guard result.audioSectionLines.count <= 1 else {
            throw VoxTypeConfigurationError.duplicateAudioSection
        }
        guard result.maximumDurationLines.count <= 1 else {
            throw VoxTypeConfigurationError.duplicateMaximumDurationKey
        }
        guard result.outputSectionLines.count <= 1 else {
            throw VoxTypeConfigurationError.duplicateOutputSection
        }
        guard result.legacyPostProcessLines.count <= 1 else {
            throw VoxTypeConfigurationError.duplicatePostProcessKey
        }
        guard result.postProcessSectionLines.count <= 1 else {
            throw VoxTypeConfigurationError.duplicatePostProcessSection
        }
        guard result.postProcessCommandLines.count <= 1 else {
            throw VoxTypeConfigurationError.duplicatePostProcessCommand
        }
        guard result.postProcessTimeoutLines.count <= 1 else {
            throw VoxTypeConfigurationError.duplicatePostProcessTimeout
        }
        guard result.legacyPostProcessLines.isEmpty
                || result.postProcessSectionLines.isEmpty else {
            throw VoxTypeConfigurationError.ambiguousPostProcessKey
        }
        guard result.ambiguousPostProcessLines.isEmpty else {
            throw VoxTypeConfigurationError.ambiguousPostProcessKey
        }
        return result
    }

    private func stringValue(at index: Int, maximumBytes: Int = 128) -> String? {
        guard let assignment = VoxTypeParsedLine.assignment(lines[index].content) else { return nil }
        let value = lines[index].content[assignment.valueRange]
            .trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return nil }
        let body = value.dropFirst().dropLast()
        var decoded = ""
        var escaping = false
        for character in body {
            if escaping {
                guard character == "\\" || character == "\"" else { return nil }
                decoded.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                decoded.append(character)
            }
        }
        guard !escaping, !decoded.isEmpty, decoded.utf8.count <= maximumBytes else { return nil }
        return decoded
    }

    private mutating func replaceValue(at index: Int, with replacement: String) {
        guard let assignment = VoxTypeParsedLine.assignment(lines[index].content) else { return }
        let content = lines[index].content
        lines[index].content = String(content[..<assignment.valueRange.lowerBound])
            + replacement
            + String(content[assignment.valueRange.upperBound...])
    }

    private func quoted(_ value: String) -> String { "\"\(value)\"" }

    private mutating func insert(_ line: VoxTypeSourceLine, at index: Int) {
        if index == lines.count { appendLine(line.content) } else { lines.insert(line, at: index) }
    }

    private mutating func appendLine(_ content: String) {
        if !lines.isEmpty, lines[lines.count - 1].terminator.isEmpty {
            lines[lines.count - 1].terminator = preferredNewline
        }
        lines.append(VoxTypeSourceLine(content: content, terminator: ""))
    }

    private mutating func appendBlankLineIfNeeded() {
        guard !lines.isEmpty, !lines[lines.count - 1].content.isEmpty else { return }
        appendLine("")
    }

    private mutating func restoreFinalNewline() {
        if endedWithNewline {
            if !lines.isEmpty, lines[lines.count - 1].terminator.isEmpty {
                lines[lines.count - 1].terminator = preferredNewline
            }
        } else if !lines.isEmpty {
            lines[lines.count - 1].terminator = ""
        }
    }
}

private struct VoxTypeConfigurationLocations {
    var sectionLines: [Int] = []
    var engineLines: [Int] = []
    var engineSectionLines: [SpeechEngineID: [Int]] = [:]
    var modelLines: [SpeechEngineID: [Int]] = [:]
    var audioSectionLines: [Int] = []
    var maximumDurationLines: [Int] = []
    var outputSectionLines: [Int] = []
    var legacyPostProcessLines: [Int] = []
    var postProcessSectionLines: [Int] = []
    var postProcessCommandLines: [Int] = []
    var postProcessTimeoutLines: [Int] = []
    var ambiguousPostProcessLines: [Int] = []
    var firstSectionLine: Int? { sectionLines.first }
}

private struct VoxTypeSourceLine {
    var content: String
    var terminator: String

    static func split(_ source: String) -> [VoxTypeSourceLine] {
        guard !source.isEmpty else { return [] }
        let bytes = Array(source.utf8)
        var result: [VoxTypeSourceLine] = []
        var start = 0
        var cursor = 0
        while cursor < bytes.count {
            if bytes[cursor] == 0x0A {
                result.append(.init(
                    content: String(decoding: bytes[start..<cursor], as: UTF8.self),
                    terminator: "\n"
                ))
                cursor += 1
                start = cursor
            } else if bytes[cursor] == 0x0D, cursor + 1 < bytes.count,
                      bytes[cursor + 1] == 0x0A {
                result.append(.init(
                    content: String(decoding: bytes[start..<cursor], as: UTF8.self),
                    terminator: "\r\n"
                ))
                cursor += 2
                start = cursor
            } else {
                cursor += 1
            }
        }
        if start < bytes.count {
            result.append(.init(
                content: String(decoding: bytes[start...], as: UTF8.self),
                terminator: ""
            ))
        }
        return result
    }
}

private struct VoxTypeParsedAssignment {
    let key: String
    let valueRange: Range<String.Index>
}

private enum VoxTypeParsedLine {
    static func rawAssignmentKey(_ line: String) -> String? {
        let commentStart = commentIndex(in: line) ?? line.endIndex
        guard let equals = unquotedIndex(of: "=", in: line, before: commentStart) else {
            return nil
        }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        if (key.first == "\"" && key.last == "\"")
            || (key.first == "'" && key.last == "'") {
            return String(key.dropFirst().dropLast())
        }
        return String(key)
    }

    static func sectionName(_ line: String) -> String? {
        let code = codeBeforeComment(line).trimmingCharacters(in: .whitespaces)
        guard code.first == "[", code.last == "]", !code.hasPrefix("[[") else { return nil }
        let raw = String(code.dropFirst().dropLast())
        let segments = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return nil }
        var names: [String] = []
        for segment in segments {
            guard let name = keyName(String(segment)) else { return nil }
            names.append(name)
        }
        return names.joined(separator: ".")
    }

    static func assignment(_ line: String) -> VoxTypeParsedAssignment? {
        let commentStart = commentIndex(in: line) ?? line.endIndex
        guard let equals = unquotedIndex(of: "=", in: line, before: commentStart) else {
            return nil
        }
        guard let key = keyName(String(line[..<equals])) else { return nil }
        var start = line.index(after: equals)
        while start < commentStart, line[start] == " " || line[start] == "\t" {
            start = line.index(after: start)
        }
        var end = commentStart
        while end > start {
            let prior = line.index(before: end)
            guard line[prior] == " " || line[prior] == "\t" else { break }
            end = prior
        }
        return .init(key: key, valueRange: start..<end)
    }

    private static func codeBeforeComment(_ line: String) -> String {
        String(line[..<(commentIndex(in: line) ?? line.endIndex)])
    }

    private static func commentIndex(in line: String) -> String.Index? {
        unquotedIndex(of: "#", in: line, before: line.endIndex)
    }

    private static func unquotedIndex(
        of target: Character,
        in line: String,
        before end: String.Index
    ) -> String.Index? {
        var quote: Character?
        var escaped = false
        var cursor = line.startIndex
        while cursor < end {
            let character = line[cursor]
            if quote == "\"" {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == quote { quote = nil }
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == target {
                return cursor
            }
            cursor = line.index(after: cursor)
        }
        return nil
    }

    private static func keyName(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if (key.first == "\"" && key.last == "\"")
            || (key.first == "'" && key.last == "'") {
            return String(key.dropFirst().dropLast())
        }
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return key
    }
}
