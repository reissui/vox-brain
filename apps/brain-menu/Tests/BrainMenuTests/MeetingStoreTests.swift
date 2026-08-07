import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct MeetingStoreTests {
    @Test
    func roundTripsUnicodeAndRejectsInvalidUtteranceTimes() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        let id = UUID()
        let record = MeetingRecord(
            id: id,
            title: "設計 review 🧠 — café",
            detectedApplication: "com.example.会議",
            startedAt: Date(timeIntervalSince1970: 1_784_112_400.125),
            endedAt: Date(timeIntervalSince1970: 1_784_112_765.5),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3",
            analysisState: .completed,
            uploadState: .delivered,
            retainedAudio: RetainedAudioMetadata(
                filename: "recording.caf",
                format: "CAF/Linear PCM",
                sizeBytes: 42_000,
                durationMilliseconds: 365_375
            )
        )
        let utterances = [
            try MeetingUtterance(
                id: UUID(),
                source: .microphone,
                startMilliseconds: 0,
                endMilliseconds: 1_250,
                text: "Hello, 世界 👋🏽\nDecision: ship “today”.",
                baseSpeakerID: "you",
                humanName: "Róisín"
            ),
            try MeetingUtterance(
                id: UUID(),
                source: .system,
                startMilliseconds: 1_100,
                endMilliseconds: 2_700,
                text: "До встречи — إلى اللقاء",
                baseSpeakerID: "remote",
                suppressed: true
            ),
        ]

        try store.save(record, utterances: utterances)

        #expect(try store.load(id) == StoredMeeting(meeting: record, utterances: utterances))
        let files = try FileManager.default.contentsOfDirectory(
            atPath: store.directoryURL(for: id).path
        ).sorted()
        #expect(files == [MeetingStore.meetingFilename, MeetingStore.transcriptFilename])
        #expect(MeetingStore.productionRootURL.path.hasSuffix(
            "/Library/Application Support/Brain/Meetings"
        ))

        #expect(throws: MeetingModelError.self) {
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: -1,
                endMilliseconds: 10,
                text: "invalid",
                baseSpeakerID: "you"
            )
        }
        #expect(throws: MeetingModelError.self) {
            try MeetingUtterance(
                source: .system,
                startMilliseconds: 11,
                endMilliseconds: 10,
                text: "invalid",
                baseSpeakerID: "remote"
            )
        }
    }

    @Test
    func persistsUtterancesAsOneChronologicalSourceAttributedTimeline() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        let record = makeRecord(title: "Chronological", startedAt: 100)
        let lateMicrophone = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 20_000,
            endMilliseconds: 25_000,
            text: "third",
            baseSpeakerID: "you",
            humanName: "You"
        )
        let middleSystem = try MeetingUtterance(
            source: .system,
            startMilliseconds: 10_000,
            endMilliseconds: 15_000,
            text: "second",
            baseSpeakerID: "remote",
            humanName: "Remote"
        )
        let earlyMicrophone = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 5_000,
            text: "first",
            baseSpeakerID: "you",
            humanName: "You"
        )

        try store.save(
            record,
            utterances: [lateMicrophone, middleSystem, earlyMicrophone]
        )

        let timeline = try store.load(record.id).utterances
        #expect(timeline.map(\.text) == ["first", "second", "third"])
        #expect(timeline.map(\.source) == [.microphone, .system, .microphone])
        #expect(timeline.map(\.humanName) == ["You", "Remote", "You"])
    }

    @Test
    func loadsAndPersistsEqualTimeUtterancesInCanonicalSourceOrder() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        let record = makeRecord(title: "Equal time", startedAt: 100)
        let system = try MeetingUtterance(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            source: .system,
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            text: "system second",
            baseSpeakerID: "remote"
        )
        let microphone = try MeetingUtterance(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            source: .microphone,
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            text: "microphone first",
            baseSpeakerID: "you"
        )

        try store.save(record, utterances: [system, microphone])
        #expect(try store.load(record.id).utterances.map(\.text) == [
            "microphone first",
            "system second",
        ])

        let transcriptURL = store.directoryURL(for: record.id)
            .appendingPathComponent(MeetingStore.transcriptFilename)
        try JSONEncoder().encode([system, microphone]).write(to: transcriptURL)
        #expect(try store.load(record.id).utterances.map(\.text) == [
            "microphone first",
            "system second",
        ])
    }

    @Test
    func listsNewestFirst() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        let oldest = makeRecord(title: "Old", startedAt: 100)
        let newest = makeRecord(title: "New", startedAt: 300)
        let middle = makeRecord(title: "Middle", startedAt: 200)

        try store.save(oldest, utterances: [])
        try store.save(newest, utterances: [])
        try store.save(middle, utterances: [])

        let records = try store.list().compactMap { entry -> MeetingRecord? in
            guard case .available(let record) = entry else { return nil }
            return record
        }
        #expect(records.map(\.id) == [newest.id, middle.id, oldest.id])
    }

    @Test
    func legacyMeetingWithoutReadOrTitleMetadataMigratesAsSeenAndPreservesItsTitle() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        let record = makeRecord(title: "Legacy project review", startedAt: 100)
        try store.save(record, utterances: [])
        let meetingURL = store.directoryURL(for: record.id)
            .appendingPathComponent(MeetingStore.meetingFilename)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: meetingURL)) as? [String: Any]
        )
        object.removeValue(forKey: "isUnread")
        object.removeValue(forKey: "titleSource")
        object.removeValue(forKey: "transcriptionState")
        object.removeValue(forKey: "transcriptionAttemptCount")
        object.removeValue(forKey: "transcriptionErrorMessage")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: meetingURL)

        let migrated = try store.load(record.id).meeting

        #expect(!migrated.isUnread)
        #expect(migrated.title == "Legacy project review")
        #expect(migrated.titleSource == .manual)
        #expect(migrated.transcriptionState == .completed)
        #expect(migrated.transcriptionAttemptCount == 0)
        #expect(migrated.transcriptionErrorMessage == nil)
    }

    @Test
    func legacyTranscriptMarkersAreFilteredAndBecomeRetryableOnlyForLegacySchema() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        let placeholderRecord = makeRecord(title: "Unavailable legacy transcript", startedAt: 100)
        let placeholder = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "[Transcript unavailable for this audio span.]",
            baseSpeakerID: "you"
        )
        let realUtterance = try MeetingUtterance(
            source: .system,
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            text: "A real recovered span.",
            baseSpeakerID: "remote"
        )
        try store.save(placeholderRecord, utterances: [placeholder, realUtterance])
        let writer = try MeetingAudioWriter(
            meetingDirectory: store.directoryURL(for: placeholderRecord.id),
            origin: placeholderRecord.startedAt
        )
        for source in MeetingAudioSource.allCases {
            _ = try writer.append(MeetingAudioSampleBuffer(
                source: source,
                sourceTimestamp: 0,
                hostTimestamp: 10,
                sampleRate: 16_000,
                channelCount: 1,
                interleavedSamples: [Float](repeating: 0.25, count: 1_600)
            ))
        }
        _ = try writer.finalize()
        try removeTranscriptionFields(
            from: store.directoryURL(for: placeholderRecord.id)
                .appendingPathComponent(MeetingStore.meetingFilename)
        )

        let migrated = try store.load(placeholderRecord.id)

        #expect(migrated.meeting.transcriptionState == .failed)
        #expect(migrated.meeting.transcriptionErrorMessage?.contains("Retry") == true)
        #expect(migrated.utterances == [realUtterance])

        let emptyRecord = makeRecord(title: "Intentionally empty legacy meeting", startedAt: 200)
        try store.save(emptyRecord, utterances: [])
        try removeTranscriptionFields(
            from: store.directoryURL(for: emptyRecord.id)
                .appendingPathComponent(MeetingStore.meetingFilename)
        )
        #expect(try store.load(emptyRecord.id).meeting.transcriptionState == .completed)

        let literalRecord = makeRecord(title: "Literal modern transcript", startedAt: 300)
        try store.save(literalRecord, utterances: [placeholder])
        let literalWriter = try MeetingAudioWriter(
            meetingDirectory: store.directoryURL(for: literalRecord.id),
            origin: literalRecord.startedAt
        )
        for source in MeetingAudioSource.allCases {
            _ = try literalWriter.append(MeetingAudioSampleBuffer(
                source: source,
                sourceTimestamp: 0,
                hostTimestamp: 10,
                sampleRate: 16_000,
                channelCount: 1,
                interleavedSamples: [Float](repeating: 0.25, count: 1_600)
            ))
        }
        _ = try literalWriter.finalize()
        let literal = try store.load(literalRecord.id)
        #expect(literal.meeting.transcriptionState == .completed)
        #expect(literal.utterances == [placeholder])
    }

    @Test
    func failedAtomicReplacementPreservesBothPriorFiles() throws {
        let temp = try StoreTestDirectory()
        let initialStore = MeetingStore(rootURL: temp.url)
        var original = makeRecord(title: "Original", startedAt: 100)
        let originalTranscript = [try makeUtterance(text: "Do not lose me")]
        try initialStore.save(original, utterances: originalTranscript)

        original.title = "Replacement"
        let replacementTranscript = [try makeUtterance(text: "Must not partially appear")]
        let failingStore = MeetingStore(rootURL: temp.url) { event in
            if event == .beforeAtomicReplacement(.meeting) {
                throw InjectedMeetingStoreFailure()
            }
        }

        #expect(throws: MeetingStoreError.atomicWriteFailed(.meeting)) {
            try failingStore.save(original, utterances: replacementTranscript)
        }

        let restored = try initialStore.load(original.id)
        #expect(restored.meeting.title == "Original")
        #expect(restored.utterances == originalTranscript)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: initialStore.directoryURL(for: original.id).path
        ).sorted() == [MeetingStore.meetingFilename, MeetingStore.transcriptFilename])
    }

    @Test
    func corruptMeetingIsUnavailableWithoutHidingValidMeetings() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        let valid = makeRecord(title: "Still visible", startedAt: 200)
        let corrupt = makeRecord(title: "Will corrupt", startedAt: 100)
        try store.save(valid, utterances: [])
        try store.save(corrupt, utterances: [try makeUtterance(text: "before")])
        try Data(#"[{"startMilliseconds":-1}]"#.utf8).write(
            to: store.directoryURL(for: corrupt.id)
                .appendingPathComponent(MeetingStore.transcriptFilename)
        )

        let entries = try store.list()
        #expect(entries.contains(.available(valid)))
        #expect(entries.contains(.unavailable(UnavailableMeeting(
            id: corrupt.id,
            directoryName: corrupt.id.uuidString,
            reason: .corruptTranscript
        ))))
        #expect(throws: MeetingStoreError.corruptMeeting(corrupt.id, .corruptTranscript)) {
            try store.load(corrupt.id)
        }
    }

    @Test
    func listingIsBoundedToOneThousandNewestRecords() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        try FileManager.default.createDirectory(at: temp.url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let transcript = try encoder.encode([MeetingUtterance]())
        var expectedNewestID: UUID?

        for index in 0..<(MeetingStore.maximumRecords + 5) {
            let record = makeRecord(title: "Meeting \(index)", startedAt: TimeInterval(index))
            if index == MeetingStore.maximumRecords + 4 {
                expectedNewestID = record.id
            }
            let directory = store.directoryURL(for: record.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try encoder.encode(record).write(
                to: directory.appendingPathComponent(MeetingStore.meetingFilename)
            )
            try transcript.write(
                to: directory.appendingPathComponent(MeetingStore.transcriptFilename)
            )
        }

        let entries = try store.list()
        #expect(entries.count == MeetingStore.maximumRecords)
        #expect(entries.first?.id == expectedNewestID)
        let oldestReturned = entries.compactMap { entry -> MeetingRecord? in
            guard case .available(let record) = entry else { return nil }
            return record
        }.last
        #expect(oldestReturned?.startedAt == Date(timeIntervalSince1970: 5))
    }

    @Test
    func storeDirectoriesAndFilesAreOwnerOnly() throws {
        let temp = try StoreTestDirectory()
        let store = MeetingStore(rootURL: temp.url)
        let record = makeRecord(title: "Private", startedAt: 100)
        try store.save(record, utterances: [try makeUtterance(text: "Private words")])

        let directory = store.directoryURL(for: record.id)
        #expect(try permissions(of: temp.url) == 0o700)
        #expect(try permissions(of: directory) == 0o700)
        #expect(try permissions(of: directory.appendingPathComponent(
            MeetingStore.meetingFilename
        )) == 0o600)
        #expect(try permissions(of: directory.appendingPathComponent(
            MeetingStore.transcriptFilename
        )) == 0o600)
    }

    @Test
    func deletionRequiresConfirmationAndIsScopedToOneMeetingDirectory() throws {
        let temp = try StoreTestDirectory()
        let meetingsRoot = temp.url.appendingPathComponent(
            "Library/Application Support/Brain/Meetings",
            isDirectory: true
        )
        let vault = temp.url.appendingPathComponent("vault", isDirectory: true)
        let remote = temp.url.appendingPathComponent("remote-server.txt")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try Data("canonical knowledge".utf8).write(to: vault.appendingPathComponent("note.md"))
        try Data("remote marker".utf8).write(to: remote)

        let store = MeetingStore(rootURL: meetingsRoot)
        let deleted = makeRecord(title: "Delete", startedAt: 200)
        let retained = makeRecord(title: "Keep", startedAt: 100)
        try store.save(deleted, utterances: [])
        try store.save(retained, utterances: [])

        #expect(throws: MeetingStoreError.deletionRequiresConfirmation) {
            try store.delete(deleted.id, confirmed: false)
        }
        #expect(FileManager.default.fileExists(atPath: store.directoryURL(for: deleted.id).path))

        try store.delete(deleted.id, confirmed: true)

        #expect(!FileManager.default.fileExists(atPath: store.directoryURL(for: deleted.id).path))
        #expect(FileManager.default.fileExists(atPath: store.directoryURL(for: retained.id).path))
        #expect(try String(
            contentsOf: vault.appendingPathComponent("note.md"),
            encoding: .utf8
        ) == "canonical knowledge")
        #expect(try String(contentsOf: remote, encoding: .utf8) == "remote marker")
    }

    @Test
    func confirmedDeletionCannotBeUndoneByALateSaveInTheSameProcess() throws {
        let temp = try StoreTestDirectory()
        let firstStore = MeetingStore(rootURL: temp.url)
        let secondStore = MeetingStore(rootURL: temp.url)
        let record = makeRecord(title: "Delete permanently", startedAt: 100)
        try firstStore.save(record, utterances: [])

        try firstStore.delete(record.id, confirmed: true)

        #expect(throws: MeetingStoreError.meetingNotFound(record.id)) {
            try secondStore.save(record, utterances: [])
        }
        #expect(!FileManager.default.fileExists(
            atPath: firstStore.directoryURL(for: record.id).path
        ))
    }

    private func makeRecord(title: String, startedAt: TimeInterval) -> MeetingRecord {
        MeetingRecord(
            title: title,
            detectedApplication: "com.example.meeting",
            startedAt: Date(timeIntervalSince1970: startedAt),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
    }

    private func makeUtterance(text: String) throws -> MeetingUtterance {
        try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 10,
            endMilliseconds: 20,
            text: text,
            baseSpeakerID: "you"
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }

    private func removeTranscriptionFields(from meetingURL: URL) throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: meetingURL)) as? [String: Any]
        )
        object.removeValue(forKey: "transcriptionState")
        object.removeValue(forKey: "transcriptionAttemptCount")
        object.removeValue(forKey: "transcriptionErrorMessage")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: meetingURL)
    }
}

private struct InjectedMeetingStoreFailure: Error {}

private final class StoreTestDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainMeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
