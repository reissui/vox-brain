import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct MeetingAnalysisServiceTests {
    @Test
    func richAndPlainContextsAreExactAndPromptIsEvidenceBounded() throws {
        let fixtures = try utteranceFixtures()
        var editor = SpeakerEditor(utterances: fixtures)
        let renamedYou = editor.rename(speakerID: "you", to: "the owner")
        let reassignedAlex = editor.reassign(utteranceIDs: [fixtures[1].id], to: "alex")
        let renamedAlex = editor.rename(speakerID: "alex", to: "Alex")
        #expect(renamedYou)
        #expect(reassignedAlex)
        #expect(renamedAlex)

        let rich = MeetingAnalysisPrompt.richContext(
            utterances: [fixtures[2], fixtures[1], fixtures[0]],
            speakerState: editor.state
        )
        let richLines = rich.split(separator: "\n").map(String.init)
        #expect(richLines.count == 2)
        #expect(richLines[0].contains(fixtures[0].id.uuidString))
        #expect(richLines[0].contains(#""startMilliseconds":0"#))
        #expect(richLines[0].contains(#""endMilliseconds":1000"#))
        #expect(richLines[0].contains(#""sourceLabel":"microphone""#))
        #expect(richLines[0].contains(#""baseSpeakerLabel":"you""#))
        #expect(richLines[0].contains(#""manualSpeakerLabel":"the owner""#))
        #expect(richLines[1].contains(fixtures[1].id.uuidString))
        #expect(richLines[1].contains(#""sourceLabel":"system""#))
        #expect(richLines[1].contains(#""baseSpeakerLabel":"remote""#))
        #expect(richLines[1].contains(#""manualSpeakerLabel":"Alex""#))
        #expect(!rich.contains(fixtures[2].id.uuidString))
        #expect(!rich.contains("echo duplicate"))

        let plain = MeetingAnalysisPrompt.plainContext(
            utterances: [fixtures[2], fixtures[1], fixtures[0]]
        )
        #expect(plain == "We should ship Friday.\nI can own the release.")
        #expect(!plain.contains("microphone"))
        #expect(!plain.contains(fixtures[0].id.uuidString))

        let prompt = MeetingAnalysisPrompt.make(
            contextChoice: .rich,
            utterances: fixtures,
            speakerState: editor.state
        ).lowercased()
        #expect(prompt.contains("suggestions as uncertain"))
        #expect(prompt.contains("manual speaker names are authoritative"))
        #expect(prompt.contains("do not invent facts"))
        #expect(prompt.contains("empty collection instead of fabricated data"))
        #expect(prompt.contains("copy-only draft"))
    }

    @Test
    func schemaAcceptsOnlyTheExactVersionedShapeAndExistingEvidence() throws {
        let utterances = try utteranceFixtures()
        let valid = analysis(
            title: "Release planning",
            quote: MeetingAnalysisQuote(
                utteranceID: utterances[0].id,
                text: "ship Friday"
            ),
            suggestions: [MeetingSpeakerSuggestion(
                utteranceID: utterances[1].id,
                suggestedName: "Alex"
            )]
        )
        let validData = try JSONEncoder().encode(valid)

        let decoded = try MeetingAnalysisSchema.decode(validData, utterances: utterances)
        #expect(decoded == valid)
        #expect(decoded.actionItems == [MeetingAnalysisActionItem(
            text: "Prepare release",
            owner: "Alex",
            due: nil
        )])

        let schema = try #require(
            JSONSerialization.jsonObject(with: MeetingAnalysisSchema.jsonSchema)
                as? [String: Any]
        )
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect((schema["required"] as? [String])?.contains("version") == true)
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect((properties["version"] as? [String: Any])?["const"] as? Int == 1)

        var extra = try object(from: validData)
        extra["invented"] = true
        #expect(throws: MeetingAnalysisSchemaError.schemaMismatch) {
            try MeetingAnalysisSchema.decode(try data(from: extra), utterances: utterances)
        }

        var missing = try object(from: validData)
        missing.removeValue(forKey: "risks")
        #expect(throws: MeetingAnalysisSchemaError.schemaMismatch) {
            try MeetingAnalysisSchema.decode(try data(from: missing), utterances: utterances)
        }

        var nestedExtra = try object(from: validData)
        var followUp = try #require(nestedExtra["followUp"] as? [String: Any])
        followUp["recipient"] = "someone@example.invalid"
        nestedExtra["followUp"] = followUp
        #expect(throws: MeetingAnalysisSchemaError.schemaMismatch) {
            try MeetingAnalysisSchema.decode(try data(from: nestedExtra), utterances: utterances)
        }

        var wrongVersion = try object(from: validData)
        wrongVersion["version"] = 2
        #expect(throws: MeetingAnalysisSchemaError.unsupportedVersion(2)) {
            try MeetingAnalysisSchema.decode(try data(from: wrongVersion), utterances: utterances)
        }

        var unknown = try object(from: validData)
        var suggestions = try #require(unknown["speakerSuggestions"] as? [[String: Any]])
        let unknownID = UUID()
        suggestions[0]["utteranceID"] = unknownID.uuidString
        unknown["speakerSuggestions"] = suggestions
        #expect(throws: MeetingAnalysisSchemaError.unknownUtteranceID(unknownID)) {
            try MeetingAnalysisSchema.decode(try data(from: unknown), utterances: utterances)
        }

        var fabricated = try object(from: validData)
        var quotes = try #require(fabricated["quotes"] as? [[String: Any]])
        quotes[0]["text"] = "words not in the utterance"
        fabricated["quotes"] = quotes
        #expect(throws: MeetingAnalysisSchemaError.fabricatedQuote(utterances[0].id)) {
            try MeetingAnalysisSchema.decode(try data(from: fabricated), utterances: utterances)
        }

        var duplicate = try object(from: validData)
        var duplicateSuggestions = try #require(
            duplicate["speakerSuggestions"] as? [[String: Any]]
        )
        duplicateSuggestions.append(duplicateSuggestions[0])
        duplicate["speakerSuggestions"] = duplicateSuggestions
        #expect(throws: MeetingAnalysisSchemaError.duplicateSpeakerSuggestion(utterances[1].id)) {
            try MeetingAnalysisSchema.decode(try data(from: duplicate), utterances: utterances)
        }
    }

    @Test
    func codexSchemaRequiresNullableActionMetadataWithoutChangingOptionalValues() throws {
        let schema = try #require(
            JSONSerialization.jsonObject(with: MeetingAnalysisSchema.jsonSchema)
                as? [String: Any]
        )
        let properties = try #require(schema["properties"] as? [String: Any])
        let actionItems = try #require(properties["actionItems"] as? [String: Any])
        let item = try #require(actionItems["items"] as? [String: Any])
        let itemProperties = try #require(item["properties"] as? [String: Any])

        #expect(Set(item["required"] as? [String] ?? []) == Set(itemProperties.keys))
        for key in ["owner", "due"] {
            let property = try #require(itemProperties[key] as? [String: Any])
            #expect(Set(property["type"] as? [String] ?? []) == ["string", "null"])
        }

        let utterances = try utteranceFixtures()
        let json = Data("""
        {
          "version": 1,
          "title": "Release planning",
          "summary": "",
          "topics": [],
          "decisions": [],
          "actionItems": [{"text":"Prepare release","owner":null,"due":null}],
          "risks": [],
          "quotes": [],
          "speakerSuggestions": [],
          "followUp": {"subject":"","body":""}
        }
        """.utf8)
        let decoded = try MeetingAnalysisSchema.decode(json, utterances: utterances)
        #expect(decoded.actionItems == [MeetingAnalysisActionItem(text: "Prepare release")])
    }

    @Test
    func automaticAnalysisRequiresFinalTranscriptAndReadyProviderWithRetryableFallback() async throws {
        let utterances = try utteranceFixtures()
        let meeting = meetingRecord()

        for state in [AIConnectionState.disabled, .missingExecutable, .timeout] {
            let provider = FakeMeetingAnalysisProvider(readiness: state, output: Data())
            let result = await MeetingAnalysisService(
                provider: provider,
                store: InMemoryMeetingAnalysisStore()
            ).analyzeAfterFinalTranscription(meeting: meeting, utterances: utterances)
            #expect(result.meeting.lifecycleState == .completed)
            #expect(result.meeting.analysisState == .failed)
            #expect(result.failure == .providerNotReady(state))
            #expect(result.isRetryable)
            #expect(provider.runCount == 0)
        }

        let notFinalProvider = FakeMeetingAnalysisProvider(readiness: .ready, output: Data())
        var notFinalMeeting = meeting
        notFinalMeeting.lifecycleState = .finalizing
        let notFinal = await MeetingAnalysisService(
            provider: notFinalProvider,
            store: InMemoryMeetingAnalysisStore()
        ).analyzeAfterFinalTranscription(meeting: notFinalMeeting, utterances: utterances)
        #expect(notFinal.failure == .transcriptionNotFinal)
        #expect(notFinalProvider.testConnectionCount == 0)
        #expect(notFinalProvider.runCount == 0)

        var processingMeeting = meeting
        processingMeeting.transcriptionState = .processing
        let processing = await MeetingAnalysisService(
            provider: notFinalProvider,
            store: InMemoryMeetingAnalysisStore()
        ).analyzeAfterFinalTranscription(meeting: processingMeeting, utterances: utterances)
        #expect(processing.failure == .transcriptionNotFinal)
        #expect(notFinalProvider.testConnectionCount == 0)
        #expect(notFinalProvider.runCount == 0)

        let timeoutProvider = FakeMeetingAnalysisProvider(
            readiness: .ready,
            error: AIProviderError.timedOut
        )
        let timedOut = await MeetingAnalysisService(
            provider: timeoutProvider,
            store: InMemoryMeetingAnalysisStore()
        ).analyzeAfterFinalTranscription(meeting: meeting, utterances: utterances)
        #expect(timedOut.failure == .providerFailure(.timedOut))
        #expect(timedOut.meeting.lifecycleState == .completed)
        #expect(timedOut.meeting.analysisState == .failed)
        #expect(timeoutProvider.runCount == 1)

        let schemaProvider = FakeMeetingAnalysisProvider(
            readiness: .ready,
            output: Data(#"{"version":1}"#.utf8)
        )
        let schemaFailure = await MeetingAnalysisService(
            provider: schemaProvider,
            store: InMemoryMeetingAnalysisStore()
        ).analyzeAfterFinalTranscription(meeting: meeting, utterances: utterances)
        #expect(schemaFailure.failure == .schemaFailure)
        #expect(schemaFailure.isRetryable)

        let providerSchemaFailure = await MeetingAnalysisService(
            provider: FakeMeetingAnalysisProvider(
                readiness: .ready,
                error: AIProviderError.schemaFailure
            ),
            store: InMemoryMeetingAnalysisStore()
        ).analyzeAfterFinalTranscription(meeting: meeting, utterances: utterances)
        #expect(providerSchemaFailure.failure == .schemaFailure)
    }

    @Test
    func suggestionsRemainAdvisoryManualNamesWinAndAcceptancePersistsAIProvenance() async throws {
        let utterances = try utteranceFixtures()
        var editor = SpeakerEditor(utterances: utterances)
        let assignedOwner = editor.reassign(utteranceIDs: [utterances[0].id], to: "owner")
        let renamedOwner = editor.rename(speakerID: "owner", to: "the owner")
        #expect(assignedOwner)
        #expect(renamedOwner)
        let payload = try JSONEncoder().encode(analysis(
            suggestions: [
                MeetingSpeakerSuggestion(
                    utteranceID: utterances[0].id,
                    suggestedName: "Wrong Manual Replacement"
                ),
                MeetingSpeakerSuggestion(
                    utteranceID: utterances[1].id,
                    suggestedName: "Alex"
                ),
            ]
        ))
        let provider = FakeMeetingAnalysisProvider(readiness: .ready, output: payload)
        let store = InMemoryMeetingAnalysisStore()
        let service = MeetingAnalysisService(provider: provider, store: store)
        let result = await service.analyzeAfterFinalTranscription(
            meeting: meetingRecord(),
            utterances: utterances,
            speakerState: editor.state
        )

        #expect(result.failure == nil)
        #expect(result.meeting.analysisState == .completed)
        #expect(result.meeting.title == "Release planning")
        #expect(result.meeting.titleSource == .analysis)
        #expect(result.speakerState.assignments[utterances[0].id] == SpeakerAssignment(
            speakerID: "owner",
            provenance: .manual
        ))
        #expect(result.speakerState.assignments[utterances[1].id]?.provenance == .sourceDefault)

        var acceptedEditor = SpeakerEditor(
            utterances: utterances,
            state: result.speakerState
        )
        let acceptedManual = try service.acceptSpeakerSuggestion(
            meetingID: result.meeting.id,
            utteranceID: utterances[0].id,
            editor: &acceptedEditor
        )
        #expect(!acceptedManual)
        let accepted = try service.acceptSpeakerSuggestion(
            meetingID: result.meeting.id,
            utteranceID: utterances[1].id,
            editor: &acceptedEditor
        )
        #expect(accepted)
        #expect(acceptedEditor.assignment(for: utterances[1].id)?.provenance == .aiAccepted)
        #expect(acceptedEditor.utterances.first { $0.id == utterances[1].id }?.humanName == "Alex")
        acceptedEditor.applyAISuggestions([utterances[1].id: "later-wrong-suggestion"])
        #expect(acceptedEditor.assignment(for: utterances[1].id)?.provenance == .aiAccepted)

        let loadedPersisted = try service.storedAnalysis(meetingID: result.meeting.id)
        let persisted = try #require(loadedPersisted)
        #expect(persisted.speakerState.assignments[utterances[0].id]?.provenance == .manual)
        #expect(persisted.speakerState.assignments[utterances[1].id]?.provenance == .aiAccepted)
    }

    @Test
    func analysisNeverOverwritesAManuallyEditedMeetingTitle() async throws {
        let utterances = try utteranceFixtures()
        var meeting = meetingRecord()
        meeting.title = "My exact title"
        meeting.titleSource = .manual
        let provider = FakeMeetingAnalysisProvider(
            readiness: .ready,
            output: try JSONEncoder().encode(analysis(title: "AI replacement"))
        )

        let result = await MeetingAnalysisService(
            provider: provider,
            store: InMemoryMeetingAnalysisStore()
        ).analyzeAfterFinalTranscription(meeting: meeting, utterances: utterances)

        #expect(result.failure == nil)
        #expect(result.meeting.title == "My exact title")
        #expect(result.meeting.titleSource == .manual)
    }

    @Test
    func failedReanalysisPreservesPriorAnalysisTranscriptAndManualSpeakerEditsAtomically() async throws {
        let utterances = try utteranceFixtures()
        var editor = SpeakerEditor(utterances: utterances)
        let assignedOwner = editor.reassign(utteranceIDs: [utterances[0].id], to: "owner")
        let renamedOwner = editor.rename(speakerID: "owner", to: "Owner")
        #expect(assignedOwner)
        #expect(renamedOwner)
        let provider = FakeMeetingAnalysisProvider(
            readiness: .ready,
            output: try JSONEncoder().encode(analysis(title: "Original analysis"))
        )
        let store = InMemoryMeetingAnalysisStore()
        let service = MeetingAnalysisService(provider: provider, store: store)
        let original = await service.analyzeAfterFinalTranscription(
            meeting: meetingRecord(),
            utterances: utterances,
            speakerState: editor.state
        )
        #expect(original.analysis?.title == "Original analysis")

        provider.output = try JSONEncoder().encode(analysis(title: "Replacement analysis"))
        store.failNextReplacement()
        let failed = await service.reanalyze(
            meeting: original.meeting,
            utterances: utterances,
            speakerState: original.speakerState
        )
        #expect(failed.failure == .persistenceFailure)
        #expect(failed.analysis?.title == "Original analysis")
        #expect(failed.utterances == utterances)
        #expect(failed.speakerState.assignments[utterances[0].id]?.provenance == .manual)
        #expect(try service.storedAnalysis(meetingID: original.meeting.id)?.analysis.title
            == "Original analysis")

        let replaced = await service.reanalyze(
            meeting: original.meeting,
            utterances: utterances,
            speakerState: original.speakerState
        )
        #expect(replaced.failure == nil)
        #expect(replaced.analysis?.title == "Replacement analysis")
        #expect(replaced.utterances == utterances)
        #expect(replaced.speakerState.assignments[utterances[0].id]?.provenance == .manual)
        #expect(store.replacementCount == 2)
    }

    @Test
    func fileStoreRoundTripsPrivatelyAndInjectedReplacementFailureKeepsPriorBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingAnalysisServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let utterances = try utteranceFixtures()
        var editor = SpeakerEditor(utterances: utterances)
        let manuallyAssigned = editor.reassign(
            utteranceIDs: [utterances[0].id],
            to: "owner"
        )
        #expect(manuallyAssigned)
        let original = StoredMeetingAnalysis(
            analysis: analysis(title: "Original file"),
            speakerState: editor.state
        )
        let store = FileMeetingAnalysisStore(rootURL: root)
        try store.replace(original, meetingID: meetingID)
        #expect(try store.load(meetingID: meetingID) == original)

        let analysisURL = root.appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(FileMeetingAnalysisStore.filename)
        let attributes = try FileManager.default.attributesOfItem(atPath: analysisURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)

        let failingStore = FileMeetingAnalysisStore(rootURL: root) { event in
            if event == .beforeAtomicReplacement(meetingID) {
                throw MeetingAnalysisStoreError.atomicWriteFailed
            }
        }
        var replacement = original
        replacement.analysis = analysis(title: "Must not appear")
        #expect(throws: MeetingAnalysisStoreError.atomicWriteFailed) {
            try failingStore.replace(replacement, meetingID: meetingID)
        }
        #expect(try store.load(meetingID: meetingID) == original)
    }

    @Test
    func followUpIsCopyOnlyAndServiceHasNoEmailOrGeneralNetworkPath() async throws {
        let utterances = try utteranceFixtures()
        let value = analysis(title: "Copy boundary")
        let provider = FakeMeetingAnalysisProvider(
            readiness: .ready,
            output: try JSONEncoder().encode(value)
        )
        let store = InMemoryMeetingAnalysisStore()
        let result = await MeetingAnalysisService(provider: provider, store: store)
            .analyzeAfterFinalTranscription(
                meeting: meetingRecord(),
                utterances: utterances
            )

        #expect(result.analysis?.followUp.subjectForCopy == "Release follow-up")
        #expect(result.analysis?.followUp.bodyForCopy == "Thanks — here are the next steps.")
        #expect(provider.testConnectionCount == 1)
        #expect(provider.runCount == 1)
        #expect(store.replacementCount == 1)

        for filename in [
            "MeetingAnalysisSchema.swift",
            "MeetingAnalysisPrompt.swift",
            "MeetingAnalysisService.swift",
        ] {
            let source = try String(
                contentsOf: sourceDirectory.appendingPathComponent(filename),
                encoding: .utf8
            )
            for forbidden in [
                "URLSession", "Network.framework", "NSAppleScript", "AppleScript",
                "mailto:", "Gmail", "MessageUI", "MFMailCompose", "SMTP",
            ] {
                #expect(!source.contains(forbidden))
            }
        }
    }

    private func utteranceFixtures() throws -> [MeetingUtterance] {
        [
            try MeetingUtterance(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000085")!,
                source: .microphone,
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                text: "We should ship Friday.",
                baseSpeakerID: "you"
            ),
            try MeetingUtterance(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000086")!,
                source: .system,
                startMilliseconds: 1_100,
                endMilliseconds: 2_000,
                text: "I can own the release.",
                baseSpeakerID: "remote"
            ),
            try MeetingUtterance(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000087")!,
                source: .system,
                startMilliseconds: 500,
                endMilliseconds: 1_100,
                text: "echo duplicate",
                baseSpeakerID: "remote",
                suppressed: true
            ),
        ]
    }

    private func meetingRecord() -> MeetingRecord {
        MeetingRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000067")!,
            title: "Meeting",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "model"
        )
    }

    private func analysis(
        title: String = "Release planning",
        quote: MeetingAnalysisQuote? = nil,
        suggestions: [MeetingSpeakerSuggestion] = []
    ) -> MeetingAnalysis {
        MeetingAnalysis(
            title: title,
            summary: "The team planned a release.",
            topics: ["Release"],
            decisions: ["Ship Friday"],
            actionItems: [MeetingAnalysisActionItem(
                text: "Prepare release",
                owner: "Alex"
            )],
            risks: [],
            quotes: quote.map { [$0] } ?? [],
            speakerSuggestions: suggestions,
            followUp: MeetingFollowUpDraft(
                subject: "Release follow-up",
                body: "Thanks — here are the next steps."
            )
        )
    }

    private func object(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func data(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/AI", isDirectory: true)
    }
}

private final class FakeMeetingAnalysisProvider: AIProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let readiness: AIConnectionState
    private let error: AIProviderError?
    private var storedOutput: Data
    private var storedTestConnectionCount = 0
    private var storedRunCount = 0

    init(readiness: AIConnectionState, output: Data) {
        self.readiness = readiness
        storedOutput = output
        error = nil
    }

    init(readiness: AIConnectionState, error: AIProviderError) {
        self.readiness = readiness
        storedOutput = Data()
        self.error = error
    }

    var output: Data {
        get { lock.withLock { storedOutput } }
        set { lock.withLock { storedOutput = newValue } }
    }

    var testConnectionCount: Int { lock.withLock { storedTestConnectionCount } }
    var runCount: Int { lock.withLock { storedRunCount } }

    func testConnection() async -> AIConnectionState {
        lock.withLock { storedTestConnectionCount += 1 }
        return readiness
    }

    func run(prompt: String, jsonSchema: Data) async throws -> Data {
        let snapshot: (Data, AIProviderError?) = lock.withLock {
            storedRunCount += 1
            return (storedOutput, self.error)
        }
        if let error = snapshot.1 { throw error }
        return snapshot.0
    }
}

private final class InMemoryMeetingAnalysisStore: MeetingAnalysisStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: StoredMeetingAnalysis] = [:]
    private var shouldFailNextReplacement = false
    private var storedReplacementCount = 0

    var replacementCount: Int { lock.withLock { storedReplacementCount } }

    func failNextReplacement() {
        lock.withLock { shouldFailNextReplacement = true }
    }

    func load(meetingID: UUID) throws -> StoredMeetingAnalysis? {
        lock.withLock { values[meetingID] }
    }

    func replace(_ value: StoredMeetingAnalysis, meetingID: UUID) throws {
        try lock.withLock {
            if shouldFailNextReplacement {
                shouldFailNextReplacement = false
                throw MeetingAnalysisStoreError.atomicWriteFailed
            }
            values[meetingID] = value
            storedReplacementCount += 1
        }
    }
}
