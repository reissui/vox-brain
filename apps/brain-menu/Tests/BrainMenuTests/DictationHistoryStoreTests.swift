import Foundation
import Testing
import BrainDictationObserverSupport
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct DictationHistoryStoreTests {
    @Test
    func importsOnlyDeliveredVoxTypeTextWithoutModifyingItsLog() throws {
        let fixture = try DictationHistoryFixture()
        defer { fixture.remove() }
        let original = """
        \u{001B}[2m2026-07-23T09:15:01.001Z\u{001B}[0m INFO Transcription completed in 0.4s: "raw draft"
        \u{001B}[2m2026-07-23T09:15:01.002Z\u{001B}[0m INFO Transcribed: "Final text, exactly.\\nSecond line"
        \u{001B}[2m2026-07-23T09:15:01.003Z\u{001B}[0m INFO Text typed via CGEvent (30 chars)
        \u{001B}[2m2026-07-23T09:16:01.002Z\u{001B}[0m INFO Transcribed: "not delivered yet"
        """
        + "\n"
        try fixture.writeVoxTypeLog(original)
        let originalData = try Data(contentsOf: fixture.voxTypeLogURL)
        let originalPermissions = try fixture.voxTypeLogPermissions()

        let store = fixture.store()
        store.importVoxTypeLog()

        #expect(store.entries.map(\.text) == ["Final text, exactly.\nSecond line"])
        #expect(try Data(contentsOf: fixture.voxTypeLogURL) == originalData)
        #expect(try fixture.voxTypeLogPermissions() == originalPermissions)

        try fixture.appendVoxTypeLog(
            "\u{001B}[2m2026-07-23T09:16:01.003Z\u{001B}[0m INFO Text pasted via clipboard + Cmd+V\n"
        )
        store.importVoxTypeLog()
        #expect(store.entries.map(\.text) == [
            "not delivered yet",
            "Final text, exactly.\nSecond line",
        ])

        store.clearAll()
        let reloaded = fixture.store()
        reloaded.importVoxTypeLog()
        #expect(reloaded.entries.isEmpty)
    }

    @Test
    func voxTypeLogCursorIsExactlyOnceAcrossRestartAppendAndRotation() throws {
        let fixture = try DictationHistoryFixture()
        defer { fixture.remove() }
        try fixture.writeVoxTypeLog(fixture.successfulLog(
            timestamp: "2026-07-23T10:00:00.001Z",
            text: "first"
        ))

        let first = fixture.store()
        first.importVoxTypeLog()
        #expect(first.entries.map(\.text) == ["first"])

        let restarted = fixture.store()
        restarted.importVoxTypeLog()
        #expect(restarted.entries.map(\.text) == ["first"])

        try fixture.appendVoxTypeLog(fixture.successfulLog(
            timestamp: "2026-07-23T10:01:00.001Z",
            text: "second"
        ))
        restarted.importVoxTypeLog()
        #expect(restarted.entries.map(\.text) == ["second", "first"])

        // A daemon can truncate and regrow a log between polls without changing
        // its inode or leaving the file shorter than the old cursor.
        try fixture.overwriteVoxTypeLog(
            String(repeating: "unrelated log line\n", count: 30)
            + fixture.successfulLog(
                timestamp: "2026-07-23T10:02:00.001Z",
                text: "after truncation"
            )
        )
        restarted.importVoxTypeLog()
        #expect(restarted.entries.map(\.text) == ["after truncation", "second", "first"])

        // Replacing the log changes its inode. Brain safely backfills the new
        // file and content/timestamp deduplication keeps earlier entries once.
        try FileManager.default.removeItem(at: fixture.voxTypeLogURL)
        try fixture.writeVoxTypeLog(fixture.successfulLog(
            timestamp: "2026-07-23T10:03:00.001Z",
            text: "after rotation"
        ))
        restarted.importVoxTypeLog()
        #expect(restarted.entries.map(\.text) == [
            "after rotation",
            "after truncation",
            "second",
            "first",
        ])
    }

    @Test
    func observerEchoesExactBytesAndCreatesAnImportableCompletedDictation() throws {
        let fixture = try DictationHistoryFixture()
        defer { fixture.remove() }
        let transcript = Data("  Exact text, punctuation — and final newline.\n".utf8)
        let handles = try fixture.observerHandles(input: transcript)
        defer { handles.close() }

        BrainDictationObserver.run(
            input: handles.input,
            output: handles.output,
            errorOutput: handles.error,
            directoryURL: fixture.dictationDirectory
        )
        try handles.output.close()
        try handles.error.close()

        #expect(try Data(contentsOf: handles.outputURL) == transcript)
        #expect((try Data(contentsOf: handles.errorURL)).isEmpty)

        let store = fixture.store()
        store.importPendingFrames()
        #expect(store.entries.map(\.text) == [String(decoding: transcript, as: UTF8.self)])
    }

    @Test
    func observerCaptureFailureNeverChangesOrLeaksVoxTypeOutput() throws {
        let fixture = try DictationHistoryFixture()
        defer { fixture.remove() }
        let secret = Data("private words must still pass through unchanged".utf8)
        let blockedDirectory = fixture.root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedDirectory)
        let handles = try fixture.observerHandles(input: secret)
        defer { handles.close() }

        BrainDictationObserver.run(
            input: handles.input,
            output: handles.output,
            errorOutput: handles.error,
            directoryURL: blockedDirectory
        )
        try handles.output.close()
        try handles.error.close()

        #expect(try Data(contentsOf: handles.outputURL) == secret)
        let error = try String(contentsOf: handles.errorURL, encoding: .utf8)
        #expect(error == "Brain dictation history capture unavailable.\n")
        #expect(!error.contains(String(decoding: secret, as: UTF8.self)))
    }

    @Test
    func observerPersistenceWorkerRunsAfterThePastePathReturns() throws {
        let fixture = try DictationHistoryFixture()
        defer { fixture.remove() }
        let worker = fixture.root.appendingPathComponent("persistence-worker")
        let marker = fixture.root.appendingPathComponent("worker-finished")
        let script = """
        #!/bin/sh
        cat >/dev/null
        sleep 1
        : >"$2"
        """
        try Data(script.utf8).write(to: worker)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: worker.path
        )

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            try BrainDictationObserver.launchPersistenceWorker(
                executableURL: worker,
                transcript: Data("paste me first".utf8),
                directoryURL: marker
            )
        }

        #expect(elapsed < .milliseconds(750))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        Thread.sleep(forTimeInterval: 2)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func restartImportIsExactlyOnceAndKeepsNewestFiveHundred() throws {
        let fixture = try DictationHistoryFixture()
        defer { fixture.remove() }
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let duplicatedID = UUID()
        let originalFrame = DictationHandoffFrame.encode(
            id: duplicatedID,
            completedAt: base,
            text: "recover me exactly"
        )
        try fixture.prepareForSyntheticFrames()
        try originalFrame.write(to: fixture.handoffURL)

        let first = fixture.store()
        first.importPendingFrames()
        #expect(first.entries.map(\.text) == ["recover me exactly"])

        // Simulate a crash after durable history persistence but before the
        // handoff acknowledgement reached storage.
        try originalFrame.write(to: fixture.handoffURL)
        let restarted = fixture.store()
        restarted.importPendingFrames()
        #expect(restarted.entries.map(\.id) == [duplicatedID])

        var bulk = Data()
        for index in 0..<505 {
            bulk.append(DictationHandoffFrame.encode(
                id: UUID(),
                completedAt: base.addingTimeInterval(Double(index + 1)),
                text: "retained \(index)"
            ))
        }
        try bulk.write(to: fixture.handoffURL)
        restarted.importPendingFrames()
        #expect(restarted.entries.count == DictationHistoryStore.retentionLimit)
        #expect(restarted.entries.first?.text == "retained 504")
        #expect(restarted.entries.last?.text == "retained 5")
    }

    @Test
    func corruptedAndOversizedFramesAreQuarantinedWithoutRevealingText() throws {
        let fixture = try DictationHistoryFixture()
        defer { fixture.remove() }
        try fixture.prepareForSyntheticFrames()
        let secret = "never print this private transcript"
        var data = DictationHandoffFrame.encode(
            id: UUID(),
            completedAt: Date(),
            text: secret
        )
        data.append(Data("BRDCT001".utf8))
        data.appendBigEndianForTest(UInt32(DictationHistoryStore.maximumTranscriptBytes + 49))
        try data.write(to: fixture.handoffURL)

        let store = fixture.store()
        store.importPendingFrames()

        #expect(store.entries.map(\.text) == [secret])
        #expect(store.errorMessage?.contains(secret) != true)
        #expect(try FileManager.default.contentsOfDirectory(
            at: store.quarantineURL,
            includingPropertiesForKeys: nil
        ).count == 1)
        #expect((try Data(contentsOf: fixture.handoffURL)).isEmpty)
    }

    @Test
    func copyDeleteAndClearPersistWithoutTouchingPendingOrQuarantineFiles() throws {
        let fixture = try DictationHistoryFixture()
        defer { fixture.remove() }
        let clipboard = RecordingDictationClipboard()
        try fixture.prepareForSyntheticFrames()
        let firstID = UUID()
        let secondID = UUID()
        var data = DictationHandoffFrame.encode(
            id: firstID,
            completedAt: Date(timeIntervalSince1970: 2),
            text: "first exact text"
        )
        data.append(DictationHandoffFrame.encode(
            id: secondID,
            completedAt: Date(timeIntervalSince1970: 3),
            text: "second exact text"
        ))
        try data.write(to: fixture.handoffURL)
        let store = fixture.store(clipboard: clipboard)
        store.importPendingFrames()

        store.copy(id: secondID)
        #expect(clipboard.value == "second exact text")
        store.delete(id: secondID)
        #expect(store.entries.map(\.id) == [firstID])

        let pending = DictationHandoffFrame.encode(
            id: UUID(),
            completedAt: Date(timeIntervalSince1970: 4),
            text: "still pending"
        )
        try pending.write(to: fixture.handoffURL)
        let marker = store.quarantineURL.appendingPathComponent("keep.marker")
        try Data("keep".utf8).write(to: marker)
        store.clearAll()

        #expect(store.entries.isEmpty)
        #expect(try Data(contentsOf: fixture.handoffURL) == pending)
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
        let reloaded = fixture.store()
        #expect(reloaded.entries.isEmpty)
    }

}

private final class RecordingDictationClipboard: DictationClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    var value: String? { lock.withLock { storedValue } }

    func write(_ text: String) {
        lock.withLock { storedValue = text }
    }
}

private final class DictationHistoryFixture {
    let root: URL
    let home: URL
    let applicationSupport: URL
    let dictationDirectory: URL
    let handoffURL: URL
    let voxTypeLogURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DictationHistoryStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        applicationSupport = home.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        dictationDirectory = applicationSupport
            .appendingPathComponent("Brain", isDirectory: true)
            .appendingPathComponent("Dictation", isDirectory: true)
        handoffURL = dictationDirectory.appendingPathComponent("handoff.frames")
        voxTypeLogURL = home.appendingPathComponent(
            "Library/Logs/voxtype/stdout.log",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func store(
        clipboard: any DictationClipboardWriting = RecordingDictationClipboard()
    ) -> DictationHistoryStore {
        DictationHistoryStore(
            directoryURL: dictationDirectory,
            voxTypeLogURL: voxTypeLogURL,
            clipboard: clipboard
        )
    }

    func writeVoxTypeLog(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: voxTypeLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: voxTypeLogURL.path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o644]
        )
    }

    func appendVoxTypeLog(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: voxTypeLogURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func overwriteVoxTypeLog(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: voxTypeLogURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    func voxTypeLogPermissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: voxTypeLogURL.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func successfulLog(timestamp: String, text: String) -> String {
        let encoded = try! String(
            data: JSONEncoder().encode(text),
            encoding: .utf8
        )!
        return """
        \(timestamp) INFO Transcribed: \(encoded)
        \(timestamp) INFO Text typed via CGEvent (\(text.count) chars)
        """
        + "\n"
    }

    func prepareForSyntheticFrames() throws {
        try FileManager.default.createDirectory(
            at: dictationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(
            atPath: handoffURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
    }

    func observerHandles(input: Data) throws -> ObserverHandles {
        let inputURL = root.appendingPathComponent("observer-input")
        let outputURL = root.appendingPathComponent("observer-output")
        let errorURL = root.appendingPathComponent("observer-error")
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: Data())
        FileManager.default.createFile(atPath: errorURL.path, contents: Data())
        return ObserverHandles(
            input: try FileHandle(forReadingFrom: inputURL),
            output: try FileHandle(forWritingTo: outputURL),
            error: try FileHandle(forWritingTo: errorURL),
            outputURL: outputURL,
            errorURL: errorURL
        )
    }

}

private final class ObserverHandles {
    let input: FileHandle
    let output: FileHandle
    let error: FileHandle
    let outputURL: URL
    let errorURL: URL

    init(
        input: FileHandle,
        output: FileHandle,
        error: FileHandle,
        outputURL: URL,
        errorURL: URL
    ) {
        self.input = input
        self.output = output
        self.error = error
        self.outputURL = outputURL
        self.errorURL = errorURL
    }

    func close() {
        try? input.close()
        try? output.close()
        try? error.close()
    }
}

private extension Data {
    mutating func appendBigEndianForTest<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
