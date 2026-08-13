import AppKit
import Foundation
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct VoiceMeetingAcceptanceTests {
    @Test
    func voiceNotesRemainCompactAndExposeTheLiveTranscript() throws {
        let island = try acceptanceIsland(suite: "voice-note-notes-exclusion")
        island.present(.meeting(RecordingIslandMeetingPresentation(
            phase: .recording,
            title: "Voice note",
            recordingKind: .voiceNote,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )))

        #expect(island.controls == [.showTranscript, .pause, .stop])
        #expect(island.panel.frame.size == RecordingIslandController.meetingPanelSize)
        island.hideImmediately()
    }

    @Test
    func externalVoxTypeCompletesOnboardingWithoutRequiringAMeetingModel() async throws {
        let fixture = try AcceptanceDirectory(prefix: "VoiceMeeting-VoxType")
        defer { fixture.remove() }
        let executable = fixture.root.appendingPathComponent("External/VoxType/bin/voxtype")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fake separately installed VoxType".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
        let runner = AcceptanceVoxTypeRunner()
        let client = VoxTypeClient(
            executableURL: executable,
            runner: runner,
            workingDirectoryURL: fixture.root.appendingPathComponent("VoxType Work"),
            environment: [
                "HOME": fixture.root.path,
                "LANG": "en_GB.UTF-8",
                "VOXTYPE_TOKEN": "must-not-cross",
            ]
        )

        let suite = "VoiceMeetingAcceptance.Onboarding.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let readyModels = AcceptanceModels(ready: Set([
            OnboardingController.defaultDictationModelID,
        ]))
        let onboarding = OnboardingController(
            voxType: AcceptanceVoxTypeInspector(executableURL: executable),
            models: readyModels,
            permissions: AcceptancePermissions(),
            opener: AcceptanceURLOpener(),
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_784_208_000) }
        )
        await onboarding.refresh()
        #expect(onboarding.isComplete)
        #expect(onboarding.check(OnboardingCheckID.voxTypeExecutable).detail.contains(executable.path))
        #expect(onboarding.check(OnboardingCheckID.voxTypeHotkey).detail.contains("Fn (push-to-talk)"))
        #expect(onboarding.check(OnboardingCheckID.meetingModel).state == .ready)

        let missingModels = AcceptanceModels(ready: [])
        let guidance = OnboardingController(
            voxType: AcceptanceVoxTypeInspector(executableURL: executable),
            models: missingModels,
            permissions: AcceptancePermissions(),
            opener: AcceptanceURLOpener(),
            defaults: defaults
        )
        await guidance.refresh()
        #expect(
            guidance.check(OnboardingCheckID.dictationModel).action
                == .installModel(OnboardingController.defaultDictationModelID)
        )
        #expect(
            guidance.check(OnboardingCheckID.meetingModel).action
                == .installModel(OnboardingController.defaultMeetingModelID)
        )
        #expect(guidance.check(OnboardingCheckID.dictationModel).state == .optional)
        #expect(guidance.check(OnboardingCheckID.meetingModel).state == .optional)

        let controller = DictationController(voxType: client, sleep: { _ in })
        let island = try acceptanceIsland(suite: "dictation")

        controller.handle(.start)
        await controller.waitForPendingWork()
        #expect(controller.state == .listening)
        island.updateDictation(controller.state, level: 0.4)
        #expect(island.presentation.controls == [.cancel])
        controller.handle(.stop)
        #expect(controller.state == .transcribing)
        await controller.waitForPendingWork()
        #expect(controller.state == .idle)

        controller.handle(.start)
        await controller.waitForPendingWork()
        controller.handle(.locked)
        #expect(controller.state == .locked)
        island.updateDictation(controller.state, level: 0.6)
        #expect(island.presentation.controls == [.cancel])
        controller.handle(.stop)
        await controller.waitForPendingWork()
        #expect(controller.state == .idle)

        let requests = await runner.requests
        let recordingArguments = requests.map(\.arguments).filter { $0.first == "record" }
        let expectedRecordingArguments: [[String]] = [
            ["record", "start", "--paste"],
            ["record", "stop", "--paste"],
            ["record", "start", "--paste"],
            ["record", "stop", "--paste"],
        ]
        #expect(recordingArguments == expectedRecordingArguments)
        #expect(requests.allSatisfy { request in
            request.executableURL == executable
                && request.standardInput == nil
                && request.environment["VOXTYPE_TOKEN"] == nil
        })
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path)
            .filter { !$0.hasSuffix("/") }
        #expect(files.filter { $0.hasSuffix(".wav") || $0.hasSuffix(".txt") }.isEmpty)
        #expect(files.filter { $0.hasSuffix("voxtype") }.count == 1)
    }

    @Test
    func detectedAndManualMeetingsUseDualFixturesRollTranscriptAndRequireExplicitStop() async throws {
        let fixture = try AcceptanceDirectory(prefix: "VoiceMeeting-Meeting")
        defer { fixture.remove() }
        let zoom = MeetingDetectedApplication(
            processIdentifier: 93,
            bundleIdentifier: "us.zoom.xos",
            displayName: "Zoom"
        )
        let anyApp = MeetingDetectedApplication(
            processIdentifier: 94,
            bundleIdentifier: "dev.example.any-app",
            displayName: "Any App"
        )

        let detectedClock = AcceptanceMeetingClock(Date(timeIntervalSince1970: 1_000))
        let detectedRecorder = AcceptanceMeetingRecorder()
        let detected = MeetingController(
            detector: MeetingDetector(ownProcessIdentifier: 999),
            recorder: detectedRecorder,
            clock: detectedClock,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        await detected.observe(.init(microphoneUsers: [zoom], isSystemSpeechActive: false))
        #expect(detected.state == .startSuggested)
        #expect(detectedRecorder.stopCount == 0)
        await detected.startRecording()
        #expect(detected.state == .recording)
        detectedClock.advance(by: 30)
        await detected.observe(.init(microphoneUsers: [], isSystemSpeechActive: false))
        detectedClock.advance(by: MeetingDetector.endSilenceDuration)
        await detected.observe(.init(microphoneUsers: [], isSystemSpeechActive: false))
        #expect(detected.state == .stopSuggested)
        #expect(detectedRecorder.stopCount == 0)
        detected.keepRecording()
        #expect(detected.state == .recording)
        #expect(detectedRecorder.stopCount == 0)
        await detected.stop()
        #expect(detected.state == .completed)
        #expect(detectedRecorder.stopCount == 1)

        let manualClock = AcceptanceMeetingClock(Date(timeIntervalSince1970: 2_000))
        let manualRecorder = AcceptanceMeetingRecorder()
        let manual = MeetingController(
            detector: MeetingDetector(ownProcessIdentifier: 999),
            recorder: manualRecorder,
            clock: manualClock,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        await manual.startRecording(application: anyApp)
        #expect(manual.state == .recording)
        #expect(manual.currentMeeting?.detectedApplication == "Any App")
        await manual.stop()
        #expect(manual.state == .completed)

        let detectedMeeting = try #require(detected.currentMeeting)
        let detectedAudio = try await dualSourceAudio(
            root: fixture.root,
            meetingID: detectedMeeting.id,
            origin: detectedMeeting.startedAt
        )
        #expect(Set(detectedAudio.tracks.map(\.source)) == Set(MeetingAudioSource.allCases))
        #expect(detectedAudio.chunks.map(\.timestampMilliseconds) == [0, 0])

        let liveClient = AcceptanceLiveClient()
        let live = LiveTranscriptController(service: try LiveTranscriptionService(
            client: liveClient,
            engine: .parakeet,
            originHostTimestamp: detectedAudio.originHostTimestamp,
            wavDirectory: fixture.root.appendingPathComponent("live-wav")
        ))
        for source in MeetingAudioSource.allCases {
            await live.append(acceptanceAudioBuffer(source: source, hostTimestamp: 100))
            await live.append(acceptanceAudioBuffer(
                source: source,
                hostTimestamp: 110,
                duration: 1.3,
                amplitude: 0
            ))
        }
        await live.waitForPendingPreview()
        #expect(live.utterances.count == 2)
        #expect(live.utterances.allSatisfy { $0.text.hasPrefix("preview") })
        let rollingLine = try #require(live.utterances.last?.text)
        let island = try acceptanceIsland(suite: "meeting")
        island.present(.meeting(RecordingIslandMeetingPresentation(
            phase: .recording,
            title: detectedMeeting.title,
            applicationName: detectedMeeting.detectedApplication,
            startedAt: detectedMeeting.startedAt,
            microphoneLevel: 0.5,
            systemLevel: 0.4,
            latestTranscriptLine: rollingLine
        )))
        #expect(island.controls == [.showTranscript, .pause, .stop])
        #expect(island.presentation != .hidden)
        await live.stop(capture: detectedAudio)
        #expect(live.isFinalized)
        #expect(live.utterances.allSatisfy { $0.text.hasPrefix("final") })
        let microphoneFinal = try #require(live.utterances.first { $0.source == .microphone })
        #expect(microphoneFinal.text == "final microphone")
        #expect(SpeakerEditor.defaultDisplayName(for: microphoneFinal.baseSpeakerID) == "You")

        let system = try MeetingUtterance(
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 2_000,
            text: "we should ship this feature",
            baseSpeakerID: "remote"
        )
        let echo = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 100,
            endMilliseconds: 1_900,
            text: "we should ship this feature",
            baseSpeakerID: "you"
        )
        let unique = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 2_000,
            endMilliseconds: 3_500,
            text: "I will own the release",
            baseSpeakerID: "you"
        )
        let suppressed = EchoDuplicateSuppressor().suppressDuplicates(in: [system, echo, unique])
        #expect(suppressed.suppressedMicrophoneUtterances.map(\.id) == [echo.id])
        var editor = SpeakerEditor(utterances: suppressed.utterances)
        let renamed = editor.renameSpeaker("remote", to: "Jamie")
        let reassigned = editor.reassign(utteranceIDs: [unique.id], to: "owner")
        #expect(renamed)
        #expect(reassigned)
        let talkTime = TalkTimeCalculator().calculate(for: editor)
        #expect(talkTime.data.contains { $0.speakerID == "remote" && $0.durationMilliseconds == 2_000 })
        #expect(talkTime.data.contains { $0.speakerID == "owner" && $0.durationMilliseconds == 1_500 })

        let store = MeetingStore(rootURL: fixture.root)
        let retention = AudioRetentionController(store: store)
        let finalUtterances = suppressed.visibleUtterances
        let detectedWithAudio = try retention.finalize(
            meeting: detectedMeeting,
            utterances: finalUtterances,
            audio: detectedAudio
        )
        #expect(detectedWithAudio.retainedAudio?.filename == AudioRetentionController.retainedFilename)
        #expect(!FileManager.default.fileExists(atPath: detectedAudio.tracks[0].fileURL.path))

        let manualMeeting = try #require(manual.currentMeeting)
        let manualAudio = try await dualSourceAudio(
            root: fixture.root,
            meetingID: manualMeeting.id,
            origin: manualMeeting.startedAt
        )
        let withAudio = try retention.finalize(
            meeting: manualMeeting,
            utterances: finalUtterances,
            audio: manualAudio
        )
        #expect(withAudio.retainedAudio?.filename == AudioRetentionController.retainedFilename)
        #expect(FileManager.default.fileExists(atPath: store.directoryURL(for: manualMeeting.id)
            .appendingPathComponent(AudioRetentionController.retainedFilename).path))
    }

    @Test
    func authenticatedCodexAndClaudeProduceStructuredV2AnalysisAndFailureUploadsRaw() async throws {
        let fixture = try AcceptanceDirectory(prefix: "VoiceMeeting-AI")
        defer { fixture.remove() }
        let utterance = try MeetingUtterance(
            id: UUID(uuidString: "93000000-0000-4000-8000-000000000001")!,
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 2_000,
            text: "Jamie will send the launch plan Friday.",
            baseSpeakerID: "remote"
        )
        let meeting = completedMeeting(
            id: UUID(uuidString: "93000000-0000-4000-8000-000000000002")!,
            title: "AI acceptance"
        )
        let analysis = MeetingAnalysis(
            title: "Launch plan",
            summary: "The launch plan is assigned.",
            topics: ["Launch"],
            decisions: ["Ship Friday"],
            actionItems: [.init(text: "Send plan", owner: "Jamie", due: "Friday")],
            risks: [],
            quotes: [.init(utteranceID: utterance.id, text: "send the launch plan")],
            speakerSuggestions: [.init(utteranceID: utterance.id, suggestedName: "Jamie")]
        )
        let encodedAnalysis = try JSONEncoder().encode(analysis)
        let directlyDecoded = try MeetingAnalysisSchema.decode(
            encodedAnalysis,
            utterances: [utterance]
        )
        #expect(directlyDecoded == analysis)

        for providerKind in [AIProvider.codex, .claude] {
            let executable = fixture.root.appendingPathComponent("bin/\(providerKind.rawValue)")
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(providerKind.rawValue.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )
            let runner = AcceptanceCLIRunner(provider: providerKind, analysis: encodedAnalysis)
            let cli = CLIProvider(
                configuration: AIProviderConfiguration(
                    provider: providerKind,
                    executableURL: executable,
                    model: providerKind == .codex ? "gpt-5.4-mini" : "claude-sonnet-4-5"
                ),
                runner: runner,
                environment: ["PATH": executable.deletingLastPathComponent().path],
                applicationSupportURL: fixture.root.appendingPathComponent("ai-\(providerKind.rawValue)")
            )
            let service = MeetingAnalysisService(
                provider: AcceptanceCLIAnalysisProvider(cli: cli),
                store: FileMeetingAnalysisStore(
                    rootURL: fixture.root.appendingPathComponent("analysis-\(providerKind.rawValue)")
                )
            )
            let result = await service.analyzeAfterFinalTranscription(
                meeting: meeting,
                utterances: [utterance]
            )
            #expect(result.failure == nil)
            #expect(result.analysis == analysis)
            #expect(result.analysis?.speakerSuggestions.first?.utteranceID == utterance.id)
            var editor = SpeakerEditor(utterances: [utterance])
            #expect(try service.acceptSpeakerSuggestion(
                meetingID: meeting.id,
                utteranceID: utterance.id,
                editor: &editor
            ))
            #expect(editor.assignment(for: utterance.id)?.provenance == .aiAccepted)
            let invocations = await runner.invocations
            #expect(invocations.count == 2)
            #expect(invocations.allSatisfy { $0.standardInput.count > 0 })
            #expect(invocations.allSatisfy { !$0.arguments.joined().contains("Jamie will") })
            if providerKind == .codex {
                #expect(invocations.last?.arguments.contains("--ephemeral") == true)
            } else {
                #expect(invocations.last?.arguments.contains("--no-session-persistence") == true)
            }
        }

        for provider in [AcceptanceDisabledAI(), AcceptanceFailingAI()] as [any AIProviding] {
            let run = await MeetingAnalysisService(
                provider: provider,
                store: FileMeetingAnalysisStore(rootURL: fixture.root.appendingPathComponent(UUID().uuidString))
            ).analyzeAfterFinalTranscription(meeting: meeting, utterances: [utterance])
            #expect(run.failure != nil)
            #expect(run.meeting.lifecycleState == .completed)

            let root = fixture.root.appendingPathComponent("fallback-\(UUID().uuidString)")
            let meetingStore = MeetingStore(rootURL: root)
            try meetingStore.save(run.meeting, utterances: run.utterances)
            let api = AcceptanceCaptureAPI()
            let upload = MeetingUploadController(
                meetingStore: meetingStore,
                analysisStore: FileMeetingAnalysisStore(rootURL: root),
                uploadStore: FileMeetingUploadStore(rootURL: root),
                api: api,
                sleep: { _ in }
            )
            await upload.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)
            #expect(upload.uploadState == .delivered)
            let request = try #require(await api.requests.first)
            #expect(request.type == .transcript)
            #expect(request.transcript?.contains(utterance.text) == true)
            #expect(request.transcript?.contains("## Summary") == false)
            #expect(request.image == nil)
            #expect(String(describing: request).contains(AcceptanceCLIRunner.providerSecret) == false)
        }
    }

    @Test
    func processedFirstPipelineRegeneratesDeduplicatesFallsBackAndPersistsIndependently() async throws {
        let fixture = try AcceptanceDirectory(prefix: "VoiceMeeting-ProcessedPipeline")
        defer { fixture.remove() }
        let utterance = try MeetingUtterance(
            id: UUID(),
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 2_000,
            text: "We discussed vox brane and will ship Friday.",
            baseSpeakerID: "remote"
        )
        var meeting = completedMeeting(id: UUID(), title: "Pipeline acceptance")
        let attempt = MeetingTranscriptAttempt(
            id: UUID(),
            createdAt: meeting.endedAt ?? meeting.startedAt,
            modelAttestation: MeetingTranscriptModelAttestation.legacy(meeting: meeting),
            utterances: [utterance],
            isSuccessful: true
        )
        meeting.selectedRawTranscriptAttemptID = attempt.id
        let artifact = MeetingTranscriptArtifact(
            meetingID: meeting.id,
            attempts: [attempt],
            selectedAttemptID: attempt.id
        )
        let processed = MeetingProcessedTranscript(
            rawAttemptID: attempt.id,
            terminologyHash: "current",
            turns: [MeetingProcessedTranscriptTurn(
                id: utterance.id,
                utteranceIDs: [utterance.id],
                startMilliseconds: 0,
                endMilliseconds: 2_000,
                speakerID: "remote",
                speakerLabel: "Remote",
                text: "We discussed Vox Brain and will ship Friday.",
                unclear: false
            )],
            bullets: [],
            corrections: [MeetingTranscriptCorrection(
                id: UUID(),
                utteranceIDs: [utterance.id],
                kind: .terminology,
                before: "vox brane",
                after: "Vox Brain",
                reason: "Glossary spelling.",
                confidence: 1
            )]
        )
        let analysis = MeetingAnalysis(
            title: "Vox Brain ship plan",
            summary: "The corrected project name is used for the readable summary.",
            topics: ["Vox Brain"],
            decisions: ["Ship Friday"],
            actionItems: [],
            risks: [],
            quotes: [.init(utteranceID: utterance.id, text: "vox brane")],
            speakerSuggestions: []
        )
        let provider = AcceptancePipelineAI(
            processing: try JSONEncoder().encode(processed),
            analysis: try JSONEncoder().encode(analysis),
            processingDelay: .milliseconds(80)
        )
        let processedStore = MeetingProcessedTranscriptStore(rootURL: fixture.root)
        let analysisStore = FileMeetingAnalysisStore(rootURL: fixture.root)
        let stale = MeetingProcessedTranscript(
            rawAttemptID: attempt.id,
            terminologyHash: "stale",
            turns: processed.turns,
            bullets: [],
            corrections: []
        )
        try processedStore.replace(stale, meetingID: meeting.id)
        let serviceA = MeetingAnalysisService(
            provider: provider,
            store: analysisStore,
            processedTranscriptStore: processedStore
        )
        let serviceB = MeetingAnalysisService(
            provider: provider,
            store: analysisStore,
            processedTranscriptStore: processedStore
        )
        let automaticMeeting = meeting
        let manualMeeting = meeting

        async let automatic = serviceA.analyzeAfterFinalTranscription(
            meeting: automaticMeeting,
            utterances: [utterance],
            artifact: artifact,
            terminology: ["Vox Brain"],
            terminologyHash: "current"
        )
        async let manual = serviceB.reanalyze(
            meeting: manualMeeting,
            utterances: [utterance],
            artifact: artifact,
            speakerState: SpeakerEditingState(),
            terminology: ["Vox Brain"],
            terminologyHash: "current"
        )
        let (automaticResult, manualResult) = await (automatic, manual)

        #expect(automaticResult.failure == nil)
        #expect(manualResult.failure == nil)
        #expect(automaticResult.analysis?.quotes.first?.text == "vox brane")
        #expect(await provider.processingRunCount == 1)
        #expect(await provider.analysisRunCount == 2)
        #expect(await provider.analysisPrompts.allSatisfy {
            $0.contains("Vox Brain")
                && $0.contains("vox brane")
                && $0.contains(utterance.id.uuidString)
        })
        #expect(try processedStore.load(
            meetingID: meeting.id,
            rawAttemptID: attempt.id,
            terminologyHash: "current"
        ) == processed)

        let supersededProcessed = MeetingProcessedTranscript(
            rawAttemptID: attempt.id,
            terminologyHash: "superseded",
            turns: processed.turns,
            bullets: [],
            corrections: processed.corrections
        )
        let newestProcessed = MeetingProcessedTranscript(
            rawAttemptID: attempt.id,
            terminologyHash: "newest",
            turns: processed.turns,
            bullets: [],
            corrections: processed.corrections
        )
        let slowOldProvider = AcceptancePipelineAI(
            processing: try JSONEncoder().encode(supersededProcessed),
            analysis: try JSONEncoder().encode(analysis),
            processingDelay: .milliseconds(160)
        )
        let fastNewProvider = AcceptancePipelineAI(
            processing: try JSONEncoder().encode(newestProcessed),
            analysis: try JSONEncoder().encode(analysis)
        )
        let slowOldService = MeetingAnalysisService(
            provider: slowOldProvider,
            store: analysisStore,
            processedTranscriptStore: processedStore
        )
        let fastNewService = MeetingAnalysisService(
            provider: fastNewProvider,
            store: analysisStore,
            processedTranscriptStore: processedStore
        )
        let supersededTask = Task {
            await slowOldService.reanalyze(
                meeting: meeting,
                utterances: [utterance],
                artifact: artifact,
                speakerState: SpeakerEditingState(),
                terminology: ["Vox Brain"],
                terminologyHash: "superseded"
            )
        }
        while await slowOldProvider.processingRunCount == 0 {
            await Task.yield()
        }
        let newestResult = await fastNewService.reanalyze(
            meeting: meeting,
            utterances: [utterance],
            artifact: artifact,
            speakerState: SpeakerEditingState(),
            terminology: ["Vox Brain"],
            terminologyHash: "newest"
        )
        let supersededResult = await supersededTask.value
        #expect(newestResult.failure == nil)
        #expect(supersededResult.failure == nil)
        #expect(try processedStore.load(
            meetingID: meeting.id,
            rawAttemptID: attempt.id,
            terminologyHash: "newest"
        ) == newestProcessed)
        #expect(try processedStore.load(
            meetingID: meeting.id,
            rawAttemptID: attempt.id,
            terminologyHash: "superseded"
        ) == nil)

        await provider.setProcessingFailure(.commandFailed(exitStatus: 9))
        await provider.setAnalysisFailure(.timedOut)
        let loadedPrior = try analysisStore.load(meetingID: meeting.id)
        let prior = try #require(loadedPrior)
        let changedHash = await serviceA.reanalyze(
            meeting: meeting,
            utterances: [utterance],
            artifact: artifact,
            speakerState: SpeakerEditingState(),
            terminology: ["Vox Brain", "Codex"],
            terminologyHash: "changed"
        )
        #expect(changedHash.failure == .providerFailure(.timedOut))
        #expect(changedHash.analysis == prior.analysis)
        #expect(changedHash.meeting.transcriptionState == .completed)
        #expect(try analysisStore.load(meetingID: meeting.id) == prior)
        #expect(try processedStore.load(
            meetingID: meeting.id,
            rawAttemptID: attempt.id,
            terminologyHash: "newest"
        ) == newestProcessed)

        let fallbackProvider = AcceptancePipelineAI(
            processing: try JSONEncoder().encode(processed),
            analysis: try JSONEncoder().encode(analysis),
            processingDelay: .milliseconds(80)
        )
        await fallbackProvider.setProcessingFailure(.commandFailed(exitStatus: 4))
        let fallbackService = MeetingAnalysisService(
            provider: fallbackProvider,
            store: FileMeetingAnalysisStore(rootURL: fixture.root.appendingPathComponent("fallback")),
            processedTranscriptStore: MeetingProcessedTranscriptStore(
                rootURL: fixture.root.appendingPathComponent("fallback")
            )
        )
        let fallback = await fallbackService.analyzeAfterFinalTranscription(
            meeting: meeting,
            utterances: [utterance],
            artifact: artifact,
            terminology: [],
            terminologyHash: "fallback"
        )
        #expect(fallback.failure == nil)
        #expect(fallback.meeting.transcriptionState == .completed)
        #expect(await fallbackProvider.analysisPrompts.first?.contains("FINAL RAW TRANSCRIPT") == true)

        let cancellationProvider = AcceptancePipelineAI(
            processing: try JSONEncoder().encode(processed),
            analysis: try JSONEncoder().encode(analysis),
            processingDelay: .milliseconds(120)
        )
        let cancellationService = MeetingAnalysisService(
            provider: cancellationProvider,
            store: FileMeetingAnalysisStore(rootURL: fixture.root.appendingPathComponent("cancel")),
            processedTranscriptStore: MeetingProcessedTranscriptStore(
                rootURL: fixture.root.appendingPathComponent("cancel")
            )
        )
        let cancellationTask = Task {
            await cancellationService.analyzeAfterFinalTranscription(
                meeting: meeting,
                utterances: [utterance],
                artifact: artifact,
                terminology: [],
                terminologyHash: "cancel"
            )
        }
        while await cancellationProvider.processingRunCount == 0 {
            await Task.yield()
        }
        cancellationTask.cancel()
        let cancelledProcessing = await cancellationTask.value
        #expect(cancelledProcessing.failure == nil)
        #expect(cancelledProcessing.meeting.transcriptionState == .completed)
        #expect(await cancellationProvider.analysisPrompts.first?.contains("FINAL RAW TRANSCRIPT") == true)

        let survivingProcessedProvider = AcceptancePipelineAI(
            processing: try JSONEncoder().encode(processed),
            analysis: try JSONEncoder().encode(analysis)
        )
        await survivingProcessedProvider.setAnalysisFailure(.timedOut)
        let survivingRoot = fixture.root.appendingPathComponent("analysis-fails")
        let survivingProcessedStore = MeetingProcessedTranscriptStore(rootURL: survivingRoot)
        let survivingService = MeetingAnalysisService(
            provider: survivingProcessedProvider,
            store: FileMeetingAnalysisStore(rootURL: survivingRoot),
            processedTranscriptStore: survivingProcessedStore
        )
        let analysisFailure = await survivingService.analyzeAfterFinalTranscription(
            meeting: meeting,
            utterances: [utterance],
            artifact: artifact,
            terminology: ["Vox Brain"],
            terminologyHash: "current"
        )
        #expect(analysisFailure.failure == .providerFailure(.timedOut))
        #expect(try survivingProcessedStore.load(
            meetingID: meeting.id,
            rawAttemptID: attempt.id,
            terminologyHash: "current"
        ) == processed)
    }

    @Test
    func reliableTranscriptEvidenceStaysAuditableReadableAndLocalThroughRecovery() async throws {
        let fixture = try AcceptanceDirectory(prefix: "VoiceMeeting-ReliableTranscript")
        defer { fixture.remove() }

        // The shared local speech gate rejects silence and impulses for either
        // source, while sustained speech is eligible for contextual previews.
        let gate = SpeechActivityGate()
        let silence = [Float](
            repeating: 0,
            count: SpeechActivityGate.samplesPerFrame * 40
        )
        var impulse = silence
        impulse[SpeechActivityGate.samplesPerFrame * 20] = 1
        let sustained = (0..<(SpeechActivityGate.samplesPerFrame * 40)).map {
            $0.isMultiple(of: 2) ? Float(0.2) : Float(-0.2)
        }
        #expect(!gate.evaluate(silence).isSpeechBearing)
        #expect(!gate.evaluate(impulse).isSpeechBearing)
        #expect(gate.evaluate(sustained).isSpeechBearing)

        var segmenter = LivePreviewSegmenter()
        for source in MeetingAudioSource.allCases {
            #expect(segmenter.append(source: source, startFrame: 0, samples: silence).isEmpty)
            #expect(segmenter.append(
                source: source,
                startFrame: Int64(silence.count),
                samples: impulse
            ).isEmpty)
            _ = segmenter.append(
                source: source,
                startFrame: Int64(silence.count + impulse.count),
                samples: sustained
            )
        }
        let contextual = segmenter.flush()
        #expect(Set(contextual.map(\.source)) == Set(MeetingAudioSource.allCases))
        #expect(contextual.allSatisfy {
            $0.endMilliseconds - $0.startMilliseconds
                <= LivePreviewSegmenter.maximumCaptureMilliseconds
        })

        // A real service boundary proves weak input never invokes VoxType and
        // every failed final speech span receives exactly one bounded retry.
        let weakClient = AcceptanceReliabilityClient(failFinal: false)
        let weakWriter = try MeetingAudioWriter(
            meetingDirectory: fixture.root.appendingPathComponent("weak"),
            origin: Date(timeIntervalSince1970: 100)
        )
        let microphoneSilence = acceptanceAudioBuffer(
            source: .microphone,
            hostTimestamp: 100,
            duration: 1,
            amplitude: 0
        )
        var systemImpulseSamples = [Float](
            repeating: 0,
            count: MeetingAudioWriter.sampleRate
        )
        systemImpulseSamples[0] = 1
        let systemImpulse = MeetingAudioSampleBuffer(
            source: .system,
            sourceTimestamp: 300,
            hostTimestamp: 100,
            sampleRate: Double(MeetingAudioWriter.sampleRate),
            channelCount: MeetingAudioWriter.channelCount,
            interleavedSamples: systemImpulseSamples
        )
        _ = try weakWriter.append(microphoneSilence)
        _ = try weakWriter.append(systemImpulse)
        let weakService = try LiveTranscriptionService(
            client: weakClient,
            engine: .whisper,
            attestedModel: "large-v3",
            originHostTimestamp: 100,
            wavDirectory: fixture.root.appendingPathComponent("weak-wav")
        )
        let weakController = LiveTranscriptController(service: weakService)
        await weakController.append(microphoneSilence)
        await weakController.append(systemImpulse)
        await weakController.stop(capture: try weakWriter.finalize())
        #expect(await weakClient.requests.isEmpty)
        #expect(weakController.utterances.isEmpty)

        let failingClient = AcceptanceReliabilityClient(failFinal: true)
        let writer = try MeetingAudioWriter(
            meetingDirectory: fixture.root.appendingPathComponent("dual"),
            origin: Date(timeIntervalSince1970: 200)
        )
        let service = try LiveTranscriptionService(
            client: failingClient,
            engine: .whisper,
            attestedModel: "large-v3",
            originHostTimestamp: 200,
            wavDirectory: fixture.root.appendingPathComponent("dual-wav")
        )
        let live = LiveTranscriptController(service: service)
        for source in MeetingAudioSource.allCases {
            let buffer = acceptanceAudioBuffer(
                source: source,
                hostTimestamp: 200,
                duration: 1,
                amplitude: 0.2
            )
            _ = try writer.append(buffer)
            await live.append(buffer)
        }
        await live.stop(capture: try writer.finalize())
        let finalRequests = await failingClient.requests.filter { $0.hasPrefix("final-") }
        #expect(finalRequests.count == 4)
        #expect(live.finalSpanOutcomes.count == 2)
        #expect(live.finalSpanOutcomes.allSatisfy {
            $0.requestCount == 2
                && $0.failure != nil
                && $0.attestedEngine == "whisper"
                && $0.attestedModel == "large-v3"
        })
        #expect(live.utterances.allSatisfy { $0.transcriptionPhase == .preview })
        let health = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: completedMeeting(id: UUID(), title: "Health summary"),
            lifecycleState: .completed,
            utterances: live.utterances,
            previewLag: live.previewLag,
            transcriptFailures: live.errors,
            controllerFailure: nil,
            levels: [:],
            now: Date(timeIntervalSince1970: 210)
        )).transcriptHealth
        #expect(health != nil)
        #expect(health?.sources.count == 2)

        let selection = SpeechEngineSelection(engine: .whisper, modelID: "large-v3")
        let attestation = VoxTypeModelAttestation(
            requestedSelection: selection,
            effectiveSelection: selection,
            verifiedAt: Date(timeIntervalSince1970: 300),
            voxTypeVersion: VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil)
        )
        let first = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "We chose orka. Thank you.",
            baseSpeakerID: "you"
        )
        let sameTurn = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 8_999,
            endMilliseconds: 9_500,
            text: "Same turn.",
            baseSpeakerID: "you"
        )
        let silenceBoundary = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 17_500,
            endMilliseconds: 18_000,
            text: "New turn at eight seconds.",
            baseSpeakerID: "you"
        )
        let speakerBoundary = try MeetingUtterance(
            source: .system,
            startMilliseconds: 18_001,
            endMilliseconds: 19_000,
            text: "Remote answer.",
            baseSpeakerID: "diarized-name"
        )
        let utterances = [first, sameTurn, silenceBoundary, speakerBoundary]
        let assembled = MeetingTranscriptTurnAssembler.assemble(utterances: utterances)
        #expect(assembled.map(\.utteranceIDs) == [
            [first.id, sameTurn.id], [silenceBoundary.id], [speakerBoundary.id],
        ])

        var meeting = MeetingRecord(
            title: "Reliable transcript",
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 340),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "large-v3",
            speechModelAttestation: attestation,
            transcriptionState: .completed
        )
        let failedOutcome = RawTranscriptionSpanOutcome(
            source: .microphone,
            originalStartMilliseconds: 8_999,
            originalEndMilliseconds: 9_500,
            attemptedStartMilliseconds: 7_499,
            attemptedEndMilliseconds: 11_000,
            speechEvidence: gate.evaluate(sustained),
            requestCount: 2,
            text: nil,
            failure: "Final transcription timed out after one retry.",
            wasCancelled: false,
            attestedEngine: "whisper",
            attestedModel: "large-v3"
        )
        let attempt = MeetingTranscriptAttempt(
            createdAt: Date(timeIntervalSince1970: 341),
            modelAttestation: MeetingTranscriptModelAttestation(meeting: meeting),
            spanOutcomes: [MeetingTranscriptSpanOutcome(failedOutcome)],
            retainedPreviews: [sameTurn],
            utterances: utterances,
            failures: [MeetingTranscriptFailureDiagnostic(LiveTranscriptFailure(
                source: .microphone,
                phase: .final,
                startMilliseconds: 8_999,
                endMilliseconds: 9_500,
                message: "Final transcription timed out after one retry."
            ))],
            isSuccessful: true
        )
        meeting.selectedRawTranscriptAttemptID = attempt.id
        let artifactStore = MeetingTranscriptArtifactStore(rootURL: fixture.root)
        let artifact = try artifactStore.append(
            attempt,
            meetingID: meeting.id,
            selecting: true
        )
        let rawURL = fixture.root.appendingPathComponent(meeting.id.uuidString)
            .appendingPathComponent(MeetingTranscriptArtifactStore.filename)
        let rawBeforeProcessing = try Data(contentsOf: rawURL)
        #expect(artifact.selectedAttempt?.retainedPreviews == [sameTurn])
        #expect(artifact.selectedAttempt?.failures.count == 1)

        let correctedTurns = assembled.map { turn in
            MeetingProcessedTranscriptTurn(
                id: turn.id,
                utteranceIDs: turn.utteranceIDs,
                startMilliseconds: turn.startMilliseconds,
                endMilliseconds: turn.endMilliseconds,
                speakerID: turn.speakerID,
                speakerLabel: turn.speakerLabel,
                text: turn.id == first.id
                    ? "We chose Orca. Thank you. Same turn."
                    : turn.text,
                unclear: false
            )
        }
        let processed = MeetingProcessedTranscript(
            rawAttemptID: attempt.id,
            terminologyHash: "orca-current",
            turns: correctedTurns,
            bullets: ["Orca was selected."],
            corrections: [MeetingTranscriptCorrection(
                id: UUID(),
                utteranceIDs: [first.id],
                kind: .terminology,
                before: "orka",
                after: "Orca",
                reason: "Private terminology supplies the spelling.",
                confidence: 1
            )]
        )
        let analysis = MeetingAnalysis(
            title: "Orca decision",
            summary: "The current processed transcript records the Orca decision.",
            topics: ["Orca"],
            decisions: ["Use Orca"],
            actionItems: [],
            risks: [],
            quotes: [.init(utteranceID: first.id, text: "Thank you")],
            speakerSuggestions: []
        )
        let provider = AcceptancePipelineAI(
            processing: try JSONEncoder().encode(processed),
            analysis: try JSONEncoder().encode(analysis)
        )
        let processedStore = MeetingProcessedTranscriptStore(rootURL: fixture.root)
        let analysisService = MeetingAnalysisService(
            provider: provider,
            store: FileMeetingAnalysisStore(rootURL: fixture.root),
            transcriptArtifactStore: artifactStore,
            processedTranscriptStore: processedStore
        )
        let result = await analysisService.analyzeAfterFinalTranscription(
            meeting: meeting,
            utterances: utterances,
            artifact: artifact,
            terminology: ["Orca"],
            terminologyHash: "orca-current"
        )
        #expect(result.failure == nil)
        #expect(result.analysis?.summary.contains("Orca") == true)
        #expect(await provider.analysisPrompts.first?.contains("We chose Orca. Thank you.") == true)
        #expect(try Data(contentsOf: rawURL) == rawBeforeProcessing)
        #expect(try processedStore.load(
            meetingID: meeting.id,
            rawAttemptID: attempt.id,
            terminologyHash: "orca-current"
        ) == processed)

        var invented = processed
        invented = MeetingProcessedTranscript(
            rawAttemptID: invented.rawAttemptID,
            terminologyHash: "invented",
            turns: invented.turns.enumerated().map { index, turn in
                MeetingProcessedTranscriptTurn(
                    id: turn.id,
                    utteranceIDs: turn.utteranceIDs,
                    startMilliseconds: turn.startMilliseconds,
                    endMilliseconds: turn.endMilliseconds,
                    speakerID: turn.speakerID,
                    speakerLabel: turn.speakerLabel,
                    text: index == 0 ? "Alice chose Orca. Thank you. Same turn." : turn.text,
                    unclear: turn.unclear
                )
            },
            bullets: [],
            corrections: []
        )
        let inventedResult = await MeetingTranscriptProcessingService(
            provider: AcceptancePipelineAI(
                processing: try JSONEncoder().encode(invented),
                analysis: try JSONEncoder().encode(analysis)
            ),
            store: processedStore
        ).process(
            meeting: meeting,
            artifact: artifact,
            terminology: ["Orca"],
            terminologyHash: "invented"
        )
        #expect(inventedResult.failure == .schemaFailure)
        #expect(try Data(contentsOf: rawURL) == rawBeforeProcessing)

        let fallbackProvider = AcceptancePipelineAI(
            processing: try JSONEncoder().encode(processed),
            analysis: try JSONEncoder().encode(analysis)
        )
        await fallbackProvider.setProcessingFailure(.timedOut)
        let fallback = await MeetingAnalysisService(
            provider: fallbackProvider,
            store: FileMeetingAnalysisStore(
                rootURL: fixture.root.appendingPathComponent("raw-fallback")
            ),
            processedTranscriptStore: MeetingProcessedTranscriptStore(
                rootURL: fixture.root.appendingPathComponent("raw-fallback")
            )
        ).analyzeAfterFinalTranscription(
            meeting: meeting,
            utterances: utterances,
            artifact: artifact,
            terminology: ["Orca"],
            terminologyHash: "fallback"
        )
        #expect(fallback.failure == nil)
        #expect(await fallbackProvider.analysisPrompts.first?.contains("FINAL RAW TRANSCRIPT") == true)
        let analysisSchema = String(decoding: MeetingAnalysisSchema.jsonSchema, as: UTF8.self)
        #expect(!analysisSchema.localizedCaseInsensitiveContains("follow-up"))
        #expect(!analysisSchema.localizedCaseInsensitiveContains("render"))
        #expect(!analysisSchema.localizedCaseInsensitiveContains("export"))

        // Local playback controls never own transcript durability. Explicit
        // audio deletion unloads the fake engine while raw/processed text stays readable.
        let meetingStore = MeetingStore(rootURL: fixture.root)
        let meetingDirectory = meetingStore.directoryURL(for: meeting.id)
        try FileManager.default.createDirectory(
            at: meetingDirectory,
            withIntermediateDirectories: true
        )
        let audioURL = meetingDirectory.appendingPathComponent(
            AudioRetentionController.retainedFilename
        )
        try Data([1, 2, 3, 4]).write(to: audioURL)
        meeting.retainedAudio = RetainedAudioMetadata(
            filename: AudioRetentionController.retainedFilename,
            format: AudioRetentionController.retainedFormat,
            sizeBytes: 4,
            durationMilliseconds: 20_000
        )
        meeting.audioRetentionState = .retained
        try meetingStore.save(meeting, utterances: utterances)
        let retention = AudioRetentionController(store: meetingStore)
        let engine = AcceptancePlaybackEngine(durationMilliseconds: 20_000)
        let playback = MeetingAudioPlaybackController(retention: retention, engine: engine)
        playback.load(meetingID: meeting.id)
        playback.play()
        playback.seek(to: 8_999)
        playback.pause()
        playback.play()
        #expect(engine.seeks == [8_999])
        #expect(playback.state == .playing)
        _ = try retention.deleteRecording(for: meeting.id, confirmed: true)
        playback.release()
        #expect(playback.state == .idle)
        #expect(playback.meetingID == nil)
        #expect(try artifactStore.load(meetingID: meeting.id)?.selectedAttempt?.utterances
            == utterances)
        #expect(try processedStore.load(
            meetingID: meeting.id,
            rawAttemptID: attempt.id,
            terminologyHash: "orca-current"
        )?.turns.first?.text.contains("Thank you") == true)

        let prompt = MeetingImprovementPrompt.make(
            meeting: meeting,
            attempt: attempt,
            processedTranscript: processed
        )
        #expect(prompt.count <= MeetingImprovementPrompt.maximumCharacters)
        #expect(prompt.contains("Failure diagnostics:"))
        #expect(!prompt.contains(first.text))
        let reviewSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/BrainMenu/Views/MeetingTranscriptReviewView.swift"),
            encoding: .utf8
        )
        #expect(reviewSource.contains("Button(\"Create Improvement Prompt\""))
        #expect(reviewSource.contains("Button(\"Copy\")"))
        #expect(!reviewSource.contains(".task {"))
    }

    @Test
    func quickCaptureUsesAdaptiveShortcutExplicitClipboardPickerAndDeliveredStatus() async throws {
        let defaults = try acceptanceDefaults("quick-hotkey")
        let panel = AcceptanceQuickPanel()
        let registrar = AcceptanceHotkeyRegistrar()
        let api = AcceptanceCaptureAPI()
        let adaptiveDelivery = CaptureController(api: api, sleep: { _ in })
        let adaptive = AdaptiveCaptureController(
            captureController: adaptiveDelivery,
            selectedTextReader: AcceptanceSelectedTextReader(
                selectedText: "https://example.com/from-selection",
                windowTitle: "Selected article"
            ),
            resultPresenter: AcceptanceAdaptiveResultPresenter()
        )
        let hotkey = CaptureHotkeyController(
            panel: panel,
            defaults: defaults,
            registrar: registrar,
            applications: AcceptanceFrontmostApplication(),
            adaptiveCapture: adaptive
        )
        let custom = CaptureHotkey(keyCode: 40, modifiers: [.command, .shift])
        try hotkey.record(keyCode: custom.keyCode, modifiers: custom.modifiers)
        #expect(hotkey.hotkey == custom)
        #expect(hotkey.start())
        registrar.trigger()
        await api.waitForRequestCount(1)
        #expect(panel.opens == 0)
        #expect(await api.requests.first?.url == "https://example.com/from-selection")

        let noteCapture = CaptureController(api: api, sleep: { _ in })
        let note = QuickCaptureController(
            mode: .note,
            captureController: noteCapture,
            clipboard: AcceptanceClipboard(text: "clipboard must stay unread"),
            permissionGate: AcceptanceQuickPermissionGate()
        )
        note.prepareToOpen(sourceApplication: nil)
        note.panelDidOpen()
        note.noteText = "explicit note"
        await note.submit()
        await noteCapture.waitForMonitoring()
        #expect(noteCapture.submissionState.isDelivered)

        let clipboard = AcceptanceClipboard(text: "https://example.com/bookmark")
        let linkCapture = CaptureController(api: api, sleep: { _ in })
        let link = QuickCaptureController(
            mode: .link,
            captureController: linkCapture,
            clipboard: clipboard,
            permissionGate: AcceptanceQuickPermissionGate()
        )
        link.prepareToOpen(sourceApplication: nil)
        #expect(clipboard.textReads == 0)
        link.panelDidOpen()
        #expect(clipboard.textReads == 1)
        await link.submit()
        await linkCapture.waitForMonitoring()
        #expect(linkCapture.submissionState.isDelivered)

        let requests = await api.requests
        #expect(requests.count == 3)
        #expect(requests.map(\.type) == [nil, .note, nil])
        #expect(requests.allSatisfy { $0.source == CaptureController.source })
    }

    private func acceptanceIsland(suite: String) throws -> RecordingIslandController {
        let defaults = try acceptanceDefaults("island-\(suite)")
        let display = RecordingIslandDisplay(
            id: "acceptance",
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        return RecordingIslandController(
            defaults: defaults,
            displaysProvider: { [display] },
            mainDisplayIDProvider: { display.id },
            frontmostProcessProvider: { 42 },
            focusPreservationHandler: { _ in },
            announcementHandler: { _ in },
            reduceMotionProvider: { true },
            sleep: { _ in }
        )
    }

    private func acceptanceDefaults(_ label: String) throws -> UserDefaults {
        let suite = "VoiceMeetingAcceptance.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func completedMeeting(id: UUID, title: String) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_784_208_000),
            endedAt: Date(timeIntervalSince1970: 1_784_208_060),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
    }

    private func dualSourceAudio(
        root: URL,
        meetingID: UUID,
        origin: Date
    ) async throws -> MeetingAudioCaptureSummary {
        let writer = try MeetingAudioWriter(
            meetingDirectory: root.appendingPathComponent(meetingID.uuidString),
            origin: origin
        )
        let capture = try MeetingAudioCapture(
            systemAudio: AcceptanceAudioSource(
                source: .system,
                buffer: acceptanceAudioBuffer(source: .system, hostTimestamp: 100)
            ),
            microphone: AcceptanceAudioSource(
                source: .microphone,
                buffer: acceptanceAudioBuffer(source: .microphone, hostTimestamp: 100)
            ),
            writer: writer
        )
        try await capture.start()
        return try await capture.stop()
    }

    private func acceptanceAudioBuffer(
        source: MeetingAudioSource,
        hostTimestamp: TimeInterval,
        duration: TimeInterval = 10,
        amplitude: Float = 0.2
    ) -> MeetingAudioSampleBuffer {
        MeetingAudioSampleBuffer(
            source: source,
            sourceTimestamp: hostTimestamp * (source == .system ? 3 : 7),
            hostTimestamp: hostTimestamp,
            sampleRate: Double(MeetingAudioWriter.sampleRate),
            channelCount: MeetingAudioWriter.channelCount,
            interleavedSamples: (0..<Int(duration * Double(MeetingAudioWriter.sampleRate))).map {
                amplitude == 0 ? 0 : ($0.isMultiple(of: 2) ? amplitude : -amplitude)
            }
        )
    }
}

private extension CaptureSubmissionState {
    var isDelivered: Bool {
        if case .delivered = self { return true }
        return false
    }
}

private final class AcceptanceDirectory: @unchecked Sendable {
    let root: URL

    init(prefix: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor AcceptanceVoxTypeRunner: VoxTypeProcessRunning {
    private(set) var requests: [VoxTypeProcessRequest] = []

    func run(_ request: VoxTypeProcessRequest) -> VoxTypeProcessOutput {
        requests.append(request)
        switch request.arguments {
        case ["--version"]:
            return VoxTypeProcessOutput(stdout: "voxtype 0.7.5\n")
        case ["status", "--format", "json", "--extended"]:
            return VoxTypeProcessOutput(stdout: #"{"class":"idle","model":"small.en","backend":"whisper"}"#)
        case ["record", "start", "--paste"], ["record", "stop", "--paste"]:
            return VoxTypeProcessOutput()
        default:
            return VoxTypeProcessOutput(stderr: Data("unexpected".utf8), exitStatus: 99)
        }
    }
}

private actor AcceptanceVoxTypeInspector: OnboardingVoxTypeInspecting {
    let executableURL: URL

    init(executableURL: URL) { self.executableURL = executableURL }

    func inspect() -> OnboardingVoxTypeInspection {
        OnboardingVoxTypeInspection(
            executableURL: executableURL,
            version: VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil),
            status: .available(VoxTypeStatusSnapshot(
                state: .idle,
                model: "small.en",
                device: "default",
                backend: "whisper"
            )),
            hotkeyConfiguration: VoxTypeHotkeyConfiguration(
                key: "FN",
                modifiers: [],
                mode: "PushToTalk"
            ),
            source: .external
        )
    }
}

private actor AcceptanceModels: OnboardingModelManaging {
    private var ready: Set<String>

    init(ready: Set<String>) { self.ready = ready }

    func refresh() -> ModelInventorySnapshot {
        ModelInventorySnapshot(availabilityByModelID: Dictionary(
            uniqueKeysWithValues: SpeechEngineCatalog.models.map {
                ($0.id, ready.contains($0.id) ? .ready : .missing)
            }
        ))
    }

    func installCatalogModel(id: String) throws -> ModelInventorySnapshot {
        ready.insert(id)
        return refresh()
    }
}

private actor AcceptancePermissions: OnboardingPermissionProviding {
    func status(for permission: OnboardingPermission) -> OnboardingAuthorizationStatus {
        .authorized
    }

    func request(_ permission: OnboardingPermission) -> OnboardingAuthorizationStatus {
        .authorized
    }
}

@MainActor
private final class AcceptanceURLOpener: OnboardingURLOpening, @unchecked Sendable {
    func open(_ url: URL) -> Bool { true }
}

@MainActor
private final class AcceptanceMeetingClock: MeetingControllingClock {
    private(set) var now: Date
    init(_ now: Date) { self.now = now }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
private final class AcceptanceMeetingRecorder: MeetingRecording {
    private(set) var stopCount = 0
    func start(_ request: MeetingRecordingRequest) async throws {}
    func pause(at date: Date) async throws {}
    func resume(with discontinuity: MeetingRecordingDiscontinuity) async throws {}
    func stop(at date: Date) async throws -> MeetingRecord? {
        stopCount += 1
        return nil
    }
    func preserveForRecovery(at date: Date, reason: MeetingRecoveryReason) async {}
}

private final class AcceptanceAudioSource: MeetingAudioSourceCapturing, @unchecked Sendable {
    let source: MeetingAudioSource
    let buffer: MeetingAudioSampleBuffer

    init(source: MeetingAudioSource, buffer: MeetingAudioSampleBuffer) {
        self.source = source
        self.buffer = buffer
    }

    func start(eventHandler: @escaping @Sendable (MeetingAudioSourceEvent) -> Void) async throws {
        eventHandler(.samples(buffer))
    }

    func stop() async {}
}

private actor AcceptanceLiveClient: LiveTranscriptionClient {
    func transcribe(wavURL: URL, engine: String) async throws -> String {
        let name = wavURL.lastPathComponent
        let source = name.contains("microphone") ? "microphone" : "system"
        return "\(name.hasPrefix("preview") ? "preview" : "final") \(source)"
    }
}

private actor AcceptanceReliabilityClient: LiveTranscriptionClient {
    let failFinal: Bool
    private(set) var requests: [String] = []

    init(failFinal: Bool) {
        self.failFinal = failFinal
    }

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        let name = wavURL.lastPathComponent
        requests.append(name)
        if failFinal, name.hasPrefix("final-") {
            throw AIProviderError.timedOut
        }
        return name.contains("microphone") ? "preview microphone" : "preview system"
    }
}

@MainActor
private final class AcceptancePlaybackEngine: MeetingAudioPlaying {
    let durationMilliseconds: Int64
    var elapsedMilliseconds: Int64 = 0
    var onProgress: (@MainActor (Int64) -> Void)?
    var onCompletion: (@MainActor () -> Void)?
    private(set) var seeks: [Int64] = []
    private(set) var stopCount = 0

    init(durationMilliseconds: Int64) {
        self.durationMilliseconds = durationMilliseconds
    }

    func load(url: URL) throws {
        elapsedMilliseconds = 0
    }

    func play() throws {}

    func pause() {}

    func stop() {
        stopCount += 1
    }

    func seek(to milliseconds: Int64) throws {
        seeks.append(milliseconds)
        elapsedMilliseconds = milliseconds
    }
}

private actor AcceptanceCLIRunner: CLIProcessRunning {
    static let providerSecret = "provider-credential-must-never-upload"
    let provider: AIProvider
    let analysis: Data
    private(set) var invocations: [CLIInvocation] = []

    init(provider: AIProvider, analysis: Data) {
        self.provider = provider
        self.analysis = analysis
    }

    func run(_ invocation: CLIInvocation) throws -> CLIProcessResult {
        invocations.append(invocation)
        let payload = invocation.standardInput == Data(CLIProvider.testConnectionPrompt.utf8)
            ? Data(#"{"status":"ready"}"#.utf8)
            : analysis
        let output: Data
        if provider == .claude {
            let structured = try JSONSerialization.jsonObject(with: payload)
            output = try JSONSerialization.data(withJSONObject: [
                "type": "result",
                "structured_output": structured,
            ])
        } else {
            output = payload
        }
        return CLIProcessResult(standardOutput: output, standardError: Data(), exitStatus: 0)
    }
}

private struct AcceptanceDisabledAI: AIProviding {
    func run(prompt: String, jsonSchema: Data) async throws -> Data {
        throw AIProviderError.disabled
    }
    func testConnection() async -> AIConnectionState { .disabled }
}

private struct AcceptanceCLIAnalysisProvider: AIProviding {
    private static let objectSchema = Data(#"{"type":"object"}"#.utf8)
    let cli: CLIProvider

    func testConnection() async -> AIConnectionState { await cli.testConnection() }

    func run(prompt: String, jsonSchema: Data) async throws -> Data {
        // The meeting service performs the complete versioned validation. The
        // CLI boundary additionally requires a JSON object before returning it.
        try await cli.run(prompt: prompt, jsonSchema: Self.objectSchema)
    }
}

private struct AcceptanceFailingAI: AIProviding {
    func run(prompt: String, jsonSchema: Data) async throws -> Data {
        throw AIProviderError.commandFailed(exitStatus: 7)
    }
    func testConnection() async -> AIConnectionState { .ready }
}

private actor AcceptancePipelineAI: AIProviding {
    let processing: Data
    let analysis: Data
    let processingDelay: Duration
    private var processingFailure: AIProviderError?
    private var analysisFailure: AIProviderError?
    private(set) var processingRunCount = 0
    private(set) var analysisRunCount = 0
    private(set) var analysisPrompts: [String] = []

    init(processing: Data, analysis: Data, processingDelay: Duration = .zero) {
        self.processing = processing
        self.analysis = analysis
        self.processingDelay = processingDelay
    }

    func setProcessingFailure(_ failure: AIProviderError?) {
        processingFailure = failure
    }

    func setAnalysisFailure(_ failure: AIProviderError?) {
        analysisFailure = failure
    }

    func testConnection() async -> AIConnectionState { .ready }

    func run(prompt: String, jsonSchema: Data) async throws -> Data {
        if jsonSchema == MeetingTranscriptProcessingSchema.jsonSchema {
            processingRunCount += 1
            if processingDelay != .zero {
                try? await Task.sleep(for: processingDelay)
            }
            if let processingFailure { throw processingFailure }
            return processing
        }
        analysisRunCount += 1
        analysisPrompts.append(prompt)
        if let analysisFailure { throw analysisFailure }
        return analysis
    }
}

private actor AcceptanceCaptureAPI: BrainCaptureAPI {
    private(set) var requests: [BrainCaptureRequest] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        requests.append(capture)
        let ready = requestWaiters.filter { requests.count >= $0.count }
        requestWaiters.removeAll { requests.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return BrainCaptureReceipt(id: idempotencyKey.uuidString.lowercased(), state: "queued")
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        BrainCaptureStatus(
            id: id,
            state: .delivered,
            retryable: false,
            error: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            deliveredAt: Date(timeIntervalSince1970: 2)
        )
    }
}

@MainActor
private final class AcceptanceQuickPanel: QuickCaptureOpening {
    private(set) var opens = 0
    func open(sourceApplication: QuickCaptureApplicationIdentity?) { opens += 1 }
}

@MainActor
private final class AcceptanceHotkeyRegistrar: CaptureHotkeyRegistering {
    private var action: (@MainActor () -> Void)?
    func register(_ hotkey: CaptureHotkey, action: @escaping @MainActor () -> Void) throws {
        self.action = action
    }
    func unregister() { action = nil }
    func trigger() { action?() }
}

@MainActor
private final class AcceptanceFrontmostApplication: FrontmostApplicationProviding {
    var frontmostApplication: QuickCaptureApplicationIdentity? {
        QuickCaptureApplicationIdentity(
            processIdentifier: 93,
            bundleIdentifier: "dev.example.editor",
            localizedName: "Editor"
        )
    }
}

@MainActor
private final class AcceptanceSelectedTextReader: SelectedTextReading {
    let selectedText: String?
    let windowTitle: String

    init(selectedText: String?, windowTitle: String) {
        self.selectedText = selectedText
        self.windowTitle = windowTitle
    }

    func snapshot(
        from application: QuickCaptureApplicationIdentity?
    ) throws -> SelectedTextSnapshot {
        SelectedTextSnapshot(selectedText: selectedText, windowTitle: windowTitle)
    }
}

@MainActor
private final class AcceptanceAdaptiveResultPresenter: AdaptiveCaptureResultPresenting {
    func present(_ failure: AdaptiveCaptureFailure) {
        Issue.record("Adaptive capture unexpectedly failed: \(failure)")
    }
}

@MainActor
private final class AcceptanceClipboard: CaptureClipboardReading {
    let text: String?
    private(set) var textReads = 0
    init(text: String?) { self.text = text }
    func readText() -> String? { textReads += 1; return text }
    func readImage() -> CaptureImagePayload? { nil }
}

@MainActor
private final class AcceptanceQuickPermissionGate: QuickCapturePermissionGating {
    func unresolvedPermission(for mode: QuickCaptureMode) -> QuickCapturePermissionBlock? { nil }
    func perform(_ action: OnboardingAction) async {}
}
