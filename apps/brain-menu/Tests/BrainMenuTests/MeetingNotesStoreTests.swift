import Foundation
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct MeetingNotesStoreTests {
    @Test
    func atomicRoundTripUsesOwnerOnlyFileAndDirectoryPermissions() throws {
        let fixture = NotesFixture()
        defer { fixture.remove() }
        let store = MeetingNotesStore(rootURL: fixture.root)
        let id = UUID()
        let exact = "First line\n\n- exact café note\n"

        #expect(try store.load(meetingID: id) == "")
        try store.save(exact, meetingID: id)

        #expect(try store.load(meetingID: id) == exact)
        let notesURL = store.notesURL(for: id)
        let directory = notesURL.deletingLastPathComponent()
        #expect(permissions(notesURL) == 0o600)
        #expect(permissions(directory) == 0o700)
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(children == [MeetingNotesStore.filename])
    }

    @Test
    func debounceCoalescesRapidEditsAtTwoHundredFiftyMilliseconds() async {
        let store = NotesStoreSpy()
        let controller = MeetingNotesController(store: store)
        let id = UUID()
        controller.attach(meetingID: id)
        await eventually { controller.state == .saved }

        controller.text = "o"
        controller.text = "on"
        controller.text = "one"
        #expect(MeetingNotesController.autosaveDelay == .milliseconds(250))
        #expect(controller.state == .saving)

        try? await Task.sleep(for: .milliseconds(350))
        await eventually { controller.state == .saved }
        #expect(store.savedValues == ["one"])
        #expect(store.saveIDs == [id])
    }

    @Test
    func stopBoundaryFlushesLatestTextWithoutWaitingForDebounce() async throws {
        let store = NotesStoreSpy()
        let controller = MeetingNotesController(
            store: store,
            autosaveDelay: .seconds(60)
        )
        let id = UUID()
        controller.attach(meetingID: id)
        await eventually { controller.state == .saved }
        controller.text = "latest text at Stop"

        await controller.flush()

        #expect(store.savedValues == ["latest text at Stop"])
        #expect(controller.state == .saved)

        let appSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/BrainMenuApp.swift"
            ),
            encoding: .utf8
        )
        #expect(
            appSource.components(separatedBy: "await meetingNotesFlushHandler?()").count - 1
                == 4
        )
    }

    @Test
    func relaunchLoadsNotesIndependentlyFromTranscriptRecovery() async throws {
        let fixture = NotesFixture()
        defer { fixture.remove() }
        let id = UUID()
        try MeetingNotesStore(rootURL: fixture.root).save("survives relaunch", meetingID: id)

        let relaunched = MeetingNotesController(
            store: MeetingNotesStore(rootURL: fixture.root)
        )
        relaunched.attach(meetingID: id)
        await eventually { relaunched.state == .saved }

        #expect(relaunched.text == "survives relaunch")
    }

    @Test
    func rejectsSymlinkAndNonRegularTargets() throws {
        let fixture = NotesFixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let id = UUID()
        let directory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        let notes = directory.appendingPathComponent(MeetingNotesStore.filename)
        try fileManager.createSymbolicLink(at: notes, withDestinationURL: outside)
        let store = MeetingNotesStore(rootURL: fixture.root)

        #expect(throws: MeetingNotesStoreError.unsafePath) {
            try store.load(meetingID: id)
        }
        #expect(throws: MeetingNotesStoreError.unsafePath) {
            try store.save("must not escape", meetingID: id)
        }

        let linkedID = UUID()
        let linkedDirectory = fixture.root.appendingPathComponent(
            linkedID.uuidString,
            isDirectory: true
        )
        try fileManager.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: directory
        )
        #expect(throws: MeetingNotesStoreError.unsafePath) {
            try store.load(meetingID: linkedID)
        }

        let danglingID = UUID()
        let danglingDirectory = fixture.root.appendingPathComponent(
            danglingID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: danglingDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: danglingDirectory.appendingPathComponent(MeetingNotesStore.filename),
            withDestinationURL: fixture.root.appendingPathComponent("missing-target")
        )
        #expect(throws: MeetingNotesStoreError.unsafePath) {
            try store.load(meetingID: danglingID)
        }

        let directoryTargetID = UUID()
        let directoryTarget = fixture.root.appendingPathComponent(
            directoryTargetID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directoryTarget.appendingPathComponent(
                MeetingNotesStore.filename,
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        #expect(throws: MeetingNotesStoreError.unsafePath) {
            try store.load(meetingID: directoryTargetID)
        }
    }

    @Test
    func enforcesOneMiBUTF8LimitOnSaveAndLoad() throws {
        let fixture = NotesFixture()
        defer { fixture.remove() }
        let store = MeetingNotesStore(rootURL: fixture.root)
        let id = UUID()
        let oversized = String(
            repeating: "é",
            count: MeetingNotesStore.maximumUTF8Bytes / 2 + 1
        )
        #expect(throws: MeetingNotesStoreError.oversized) {
            try store.save(oversized, meetingID: id)
        }

        let directory = store.notesURL(for: id).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: MeetingNotesStore.maximumUTF8Bytes + 1)
            .write(to: store.notesURL(for: id))
        #expect(throws: MeetingNotesStoreError.oversized) {
            try store.load(meetingID: id)
        }
    }

    @Test
    func malformedNotesReportTheirOwnErrorWithoutHidingTranscript() async throws {
        let fixture = NotesFixture()
        defer { fixture.remove() }
        let id = UUID()
        let meetingStore = MeetingStore(rootURL: fixture.root)
        let meeting = completedMeeting(id: id)
        let utterance = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "Transcript remains readable.",
            baseSpeakerID: "you"
        )
        try meetingStore.save(meeting, utterances: [utterance])
        let notesStore = MeetingNotesStore(rootURL: fixture.root)
        try Data([0xff, 0xfe]).write(to: notesStore.notesURL(for: id))

        #expect(throws: MeetingNotesStoreError.invalidUTF8) {
            try notesStore.load(meetingID: id)
        }
        let notesController = MeetingNotesController(store: notesStore)
        notesController.attach(meetingID: id)
        await eventually {
            if case .error = notesController.state { return true }
            return false
        }
        if case .error(let message) = notesController.state {
            #expect(message.contains("UTF-8"))
        } else {
            Issue.record("Malformed notes must report a notes-specific error")
        }
        let stored = try meetingStore.load(id)
        #expect(stored.utterances == [utterance])

        let api = NotesCaptureAPI()
        let uploader = MeetingUploadController(
            meetingStore: meetingStore,
            notesStore: notesStore,
            analysisStore: FileMeetingAnalysisStore(rootURL: fixture.root),
            uploadStore: FileMeetingUploadStore(rootURL: fixture.root),
            api: api,
            sleep: { _ in }
        )
        await uploader.uploadAfterFinalTranscriptPersistence(meetingID: id)
        let request = try #require(await api.request)
        #expect(request.transcript?.contains("Transcript remains readable.") == true)
        #expect(request.transcript?.contains("## Notes") == false)
    }

    private func permissions(_ url: URL) -> Int {
        let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        return value?.intValue ?? -1
    }

    private func eventually(
        attempts: Int = 500,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }

    private func completedMeeting(id: UUID) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: "Notes test",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model"
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class NotesStoreSpy: MeetingNotesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saves: [(UUID, String)] = []

    var savedValues: [String] { locked { saves.map(\.1) } }
    var saveIDs: [UUID] { locked { saves.map(\.0) } }

    func load(meetingID: UUID) throws -> String { "" }

    func save(_ notes: String, meetingID: UUID) throws {
        locked { saves.append((meetingID, notes)) }
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private actor NotesCaptureAPI: BrainCaptureAPI {
    private(set) var request: BrainCaptureRequest?

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        request = capture
        return BrainCaptureReceipt(id: "notes-capture", state: "queued")
    }

    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        BrainCaptureStatus(
            id: id,
            state: .delivered,
            retryable: false,
            error: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001),
            deliveredAt: Date(timeIntervalSince1970: 1_001)
        )
    }
}

private final class NotesFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingNotesTests-\(UUID().uuidString)", isDirectory: true)

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
