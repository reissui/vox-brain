import Foundation
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct MeetingTerminologyStoreTests {
    @Test
    func normalizesUnicodeWhitespaceDeduplicatesAndSortsWithoutChangingSpelling() throws {
        let fixture = TerminologyFixture()
        defer { fixture.remove() }
        let store = MeetingTerminologyStore(fileURL: fixture.file)

        store.add("  Zeta\tProject  ")
        store.add("alpha\nteam")
        store.add("ALPHA TEAM")
        store.add("café\u{00A0}notes")

        #expect(store.terms == ["alpha team", "café notes", "Zeta Project"])
        #expect(store.errorMessage == nil)
    }

    @Test
    func rejectsEmptyAndOverlongUnicodeScalarTermsWithoutChangingLastValidValue() throws {
        let fixture = TerminologyFixture()
        defer { fixture.remove() }
        let store = MeetingTerminologyStore(fileURL: fixture.file)
        store.add("Keep")
        let original = store.terms

        store.add(" \n\t ")
        #expect(store.terms == original)
        #expect(store.errorMessage != nil)

        store.add(String(repeating: "🙂", count: 81))
        #expect(store.terms == original)
        #expect(store.errorMessage != nil)
    }

    @Test
    func enforcesLimitAndHasDeterministicContentHash() throws {
        let fixture = TerminologyFixture()
        defer { fixture.remove() }
        let store = MeetingTerminologyStore(fileURL: fixture.file)
        for index in 0..<MeetingTerminologyStore.maximumTerms { store.add("Term \(index)") }
        let hash = store.contentHash

        store.add("one too many")
        #expect(store.terms.count == MeetingTerminologyStore.maximumTerms)
        #expect(store.errorMessage != nil)
        #expect(store.contentHash == hash)

        let reopened = MeetingTerminologyStore(fileURL: fixture.file)
        #expect(reopened.contentHash == hash)
        #expect(reopened.terms == store.terms)
    }

    @Test
    func roundTripIsVersionedAndPrivate() throws {
        let fixture = TerminologyFixture()
        defer { fixture.remove() }
        let store = MeetingTerminologyStore(fileURL: fixture.file)
        store.add("Brain")

        let data = try Data(contentsOf: fixture.file)
        #expect(String(decoding: data, as: UTF8.self).contains("\"version\":1"))
        #expect(terminologyPermissions(fixture.file) == 0o600)
        #expect(terminologyPermissions(fixture.root) == 0o700)
        #expect(MeetingTerminologyStore(fileURL: fixture.file).terms == ["Brain"])
    }

    @Test
    func rejectsUnsafeTargetsAndPreservesLastValidTermsOnWriteFailure() throws {
        let fixture = TerminologyFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let store = MeetingTerminologyStore(fileURL: fixture.file)
        store.add("Original")
        let originalData = try Data(contentsOf: fixture.file)
        try fileManager.removeItem(at: fixture.file)
        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        try fileManager.createSymbolicLink(at: fixture.file, withDestinationURL: outside)

        store.add("Must not write")
        #expect(store.terms == ["Original"])
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(store.errorMessage != nil)

        try fileManager.removeItem(at: fixture.file)
        try originalData.write(to: fixture.file)
        try fileManager.removeItem(at: fixture.file)
        try fileManager.createDirectory(at: fixture.file, withIntermediateDirectories: false)
        let reopened = MeetingTerminologyStore(fileURL: fixture.file)
        #expect(reopened.terms.isEmpty)
        #expect(reopened.errorMessage != nil)
    }
}

private final class TerminologyFixture {
    let root: URL
    let file: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTerminologyStoreTests.\(UUID().uuidString)", isDirectory: true)
        file = root.appendingPathComponent(MeetingTerminologyStore.filename)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func terminologyPermissions(_ url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
}
