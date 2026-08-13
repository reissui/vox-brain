import CryptoKit
import Darwin
import Foundation
import Observation

enum MeetingTerminologyStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidTerm
    case limitReached
    case unsafeStorage
    case invalidStorage
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidTerm: "Terminology must be 1 to 80 Unicode characters."
        case .limitReached: "You can save up to 256 terminology entries."
        case .unsafeStorage: "Meeting terminology is stored at an unsafe filesystem location."
        case .invalidStorage: "Meeting terminology could not be read."
        case .persistenceFailed: "Meeting terminology could not be saved."
        }
    }
}

/// Owner-only corrections applied locally after a meeting transcript is processed.
@MainActor
@Observable
final class MeetingTerminologyStore {
    nonisolated static let filename = "meeting-terminology.json"
    nonisolated static let version = 1
    nonisolated static let maximumTerms = 256
    nonisolated static let maximumTermUnicodeScalars = 80

    private(set) var terms: [String] = []
    private(set) var errorMessage: String?

    let fileURL: URL
    @ObservationIgnored private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = (fileURL ?? Self.defaultFileURL(fileManager: fileManager))
            .standardizedFileURL
        self.fileManager = fileManager
        reload()
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Brain", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// A stable SHA-256 of the canonical, sorted terminology content. Consumers
    /// can use it to decide whether a processed transcript is stale.
    var contentHash: String {
        let canonical = terms.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func reload() {
        do {
            let loaded = try load()
            terms = loaded
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
        }
    }

    func add(_ rawTerm: String) {
        mutate { values in
            let term = try Self.normalizedTerm(rawTerm)
            guard !values.contains(where: { Self.sameTerm($0, term) }) else { return }
            guard values.count < Self.maximumTerms else { throw MeetingTerminologyStoreError.limitReached }
            values.append(term)
        }
    }

    func replace(_ existingTerm: String, with rawTerm: String) {
        mutate { values in
            guard let index = values.firstIndex(of: existingTerm) else { return }
            let term = try Self.normalizedTerm(rawTerm)
            if values.indices.contains(where: {
                $0 != index && Self.sameTerm(values[$0], term)
            }) {
                // An edit which merges two spellings keeps the existing spelling.
                values.remove(at: index)
            } else {
                values[index] = term
            }
        }
    }

    func remove(_ term: String) {
        mutate { values in
            values.removeAll { $0 == term }
        }
    }

    private func mutate(_ change: (inout [String]) throws -> Void) {
        do {
            var proposed = terms
            try change(&proposed)
            proposed = try Self.validatedAndSorted(proposed)
            guard proposed != terms else { return }
            try save(proposed)
            terms = proposed
            errorMessage = nil
        } catch {
            // The in-memory and on-disk last valid values remain untouched.
            errorMessage = message(for: error)
        }
    }

    private func load() throws -> [String] {
        guard let kind = try itemKind(at: fileURL) else { return [] }
        guard kind == .regular else { throw MeetingTerminologyStoreError.unsafeStorage }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw MeetingTerminologyStoreError.invalidStorage
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == Self.version else {
                throw MeetingTerminologyStoreError.invalidStorage
            }
            return try Self.validatedAndSorted(document.terms)
        } catch let error as MeetingTerminologyStoreError {
            throw error
        } catch {
            throw MeetingTerminologyStoreError.invalidStorage
        }
    }

    private func save(_ values: [String]) throws {
        do {
            try ensurePrivateDirectory(fileURL.deletingLastPathComponent())
            if let kind = try itemKind(at: fileURL), kind != .regular {
                throw MeetingTerminologyStoreError.unsafeStorage
            }
            let data = try JSONEncoder().encode(Document(version: Self.version, terms: values))
            try writeAtomically(data, to: fileURL)
        } catch let error as MeetingTerminologyStoreError {
            throw error
        } catch {
            throw MeetingTerminologyStoreError.persistenceFailed
        }
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        if let kind = try itemKind(at: directory) {
            guard kind == .directory else { throw MeetingTerminologyStoreError.unsafeStorage }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(Self.filename).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw MeetingTerminologyStoreError.persistenceFailed }
        var openDescriptor = true
        defer {
            if openDescriptor { Darwin.close(descriptor) }
            try? fileManager.removeItem(at: temporary)
        }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw MeetingTerminologyStoreError.persistenceFailed }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0, Darwin.close(descriptor) == 0 else {
                throw MeetingTerminologyStoreError.persistenceFailed
            }
            openDescriptor = false
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw MeetingTerminologyStoreError.persistenceFailed
            }
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: destination.path)
        } catch let error as MeetingTerminologyStoreError {
            throw error
        } catch {
            throw MeetingTerminologyStoreError.persistenceFailed
        }
    }

    private enum ItemKind { case regular, directory, other }

    private func itemKind(at url: URL) throws -> ItemKind? {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            if errno == ENOENT { return nil }
            throw MeetingTerminologyStoreError.unsafeStorage
        }
        switch information.st_mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFDIR: return .directory
        default: return .other // Includes symlinks: never follow them.
        }
    }

    private static func normalizedTerm(_ rawTerm: String) throws -> String {
        let normalized = rawTerm.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty,
              normalized.unicodeScalars.count <= maximumTermUnicodeScalars else {
            throw MeetingTerminologyStoreError.invalidTerm
        }
        return normalized
    }

    private static func validatedAndSorted(_ values: [String]) throws -> [String] {
        guard values.count <= maximumTerms else { throw MeetingTerminologyStoreError.limitReached }
        var unique: [String] = []
        for value in values {
            let normalized = try normalizedTerm(value)
            guard !unique.contains(where: { sameTerm($0, normalized) }) else {
                throw MeetingTerminologyStoreError.invalidStorage
            }
            unique.append(normalized)
        }
        return unique.sorted { left, right in
            let result = left.caseInsensitiveCompare(right)
            return result == .orderedSame ? left < right : result == .orderedAscending
        }
    }

    private static func sameTerm(_ left: String, _ right: String) -> Bool {
        left.caseInsensitiveCompare(right) == .orderedSame
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Meeting terminology could not be saved."
    }

    private struct Document: Codable {
        let version: Int
        let terms: [String]
    }
}
