import AppKit
import Foundation
import Testing

@testable import BrainMenu

extension AppIntegrationTests {
    @MainActor
    @Suite(.serialized)
    struct LocalLiveMeetingAcceptanceTests {
        @Test
        func completeLocalMeetingJourneyStaysLocalAndDurable() async throws {
            let fixture = try LocalLiveMeetingFixture()
            defer { fixture.remove() }
            let defaults = try #require(UserDefaults(suiteName: fixture.defaultsSuite))
            defer { defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

            let configuration = BrainLocalConfiguration(
                vaultPath: fixture.vault.path,
                cliPath: fixture.cli.path
            )
            let store = BrainStore(
                client: nil,
                refreshInterval: .seconds(3_600),
                defaults: defaults
            )
            await store.configureLocal(configuration: configuration)
            let localClient = try LocalBrainClient(configuration: configuration)

            #expect(store.isReady)
            #expect(store.status?.vault.path == fixture.vault.path)
            #expect(
                FileManager.default.fileExists(
                    atPath: fixture.vault
                        .appendingPathComponent(LocalBrainClient.markerFilename).path))
            #expect(BrainRuntime.localConfiguration(defaults: defaults) == configuration)
            #expect(
                defaults.persistentDomain(forName: fixture.defaultsSuite)?.keys
                    .allSatisfy {
                        !$0.lowercased().contains("remote")
                            && !$0.lowercased().contains("pair")
                            && !$0.lowercased().contains("deployment")
                    } == true)

            let meetingStore = MeetingStore(rootURL: fixture.meetings)
            let notesStore = MeetingNotesStore(rootURL: fixture.meetings)
            let recorder = try LocalLiveMeetingRecorder(
                root: fixture.meetings,
                meetingStore: meetingStore
            )
            let meeting = MeetingController(
                detector: LocalLiveMeetingDetector(),
                recorder: recorder,
                speechEngine: "whisper",
                speechModel: "large-v3",
                modelAttester: LocalLiveMeetingModelAttester(
                    result: .success(.largeV3)
                )
            )
            let island = RecordingIslandController(
                defaults: defaults,
                displaysProvider: { [] },
                mainDisplayIDProvider: { nil },
                frontmostProcessProvider: { nil },
                focusPreservationHandler: { _ in },
                announcementHandler: { _ in },
                reduceMotionProvider: { true },
                panelPresentationHandler: { _ in }
            )
            let graph = BrainAppControllerGraph(
                store: store,
                capture: CaptureController(api: localClient, defaults: defaults, sleep: { _ in }),
                meeting: meeting,
                meetingNotesStore: notesStore,
                recordingIsland: island,
                meetings: MeetingsController(
                    store: meetingStore,
                    analysisStore: FileMeetingAnalysisStore(rootURL: fixture.meetings)
                ),
                audioRetention: AudioRetentionController(store: meetingStore),
                meetingAnalysisFactory: { nil }
            )
            // This acceptance panel does not test frame restoration. Release
            // the process-global autosave name so the dedicated panel suite
            // can exercise that contract independently.
            graph.meetingLivePanel.panel.setFrameAutosaveName("")
            defer {
                graph.meetingLivePanel.hide()
                island.hideImmediately()
            }

            #expect(graph.launchDestination == .dashboard)
            let applicationWasActive = NSApplication.shared.isActive
            await meeting.startRecording(application: nil)
            await eventually { graph.meetingNotes.state == .saved }

            let meetingID = try #require(meeting.currentMeeting?.id)
            #expect(meeting.currentMeeting?.requestedSpeechSelection == .largeV3)
            #expect(meeting.currentMeeting?.effectiveSpeechSelection == .largeV3)
            #expect(meeting.currentMeeting?.speechVerificationState == .verified)
            let applicationIsActiveAfterPresentation = NSApplication.shared.isActive
            #expect(meeting.state == .recording)
            #expect(graph.meetingLivePanel.isPresented)
            #expect(applicationIsActiveAfterPresentation == applicationWasActive)
            #expect(graph.meetingLivePanel.recordingKind == .meeting)
            #expect(graph.meetingLiveDashboard.selectedTab == .transcript)
            #expect(
                graph.meetingLiveDashboard.transcriptController
                    === recorder.liveTranscriptController)
            #expect(
                recorder.liveTranscriptController?.utterances.map(\.text)
                    == [LocalLiveMeetingVoxTypeClient.previewText])

            graph.meetingLiveDashboard.selectTab(.notes)
            #expect(graph.meetingLiveDashboard.selectedTab == .notes)
            graph.meetingNotes.text = "First thought\nLatest owner-authored note."
            let originalPanel = graph.meetingLivePanel.panel
            #expect(!graph.meetingLivePanel.windowShouldClose(try #require(originalPanel)))
            #expect(!graph.meetingLivePanel.isPresented)
            #expect(meeting.state == .recording)
            #expect(recorder.stopCount == 0)
            #expect(graph.meetingNotes.text == "First thought\nLatest owner-authored note.")

            graph.meetingLivePanel.showTranscript()
            #expect(graph.meetingLivePanel.isPresented)
            #expect(graph.meetingLivePanel.panel === originalPanel)
            #expect(
                graph.meetingLiveDashboard.transcriptController
                    === recorder.liveTranscriptController)
            #expect(meeting.state == .recording)
            #expect(recorder.stopCount == 0)

            let latestNotes = "Decisions\n\n- Ship the local meeting panel exactly as tested."
            graph.meetingNotes.text = latestNotes
            await meeting.stop()

            #expect(meeting.state == .completed)
            #expect(recorder.stopCount == 1)
            #expect(recorder.liveTranscriptController?.isFinalized == true)
            #expect(
                recorder.liveTranscriptController?.utterances.map(\.text)
                    == [LocalLiveMeetingVoxTypeClient.finalText])
            #expect(
                recorder.liveTranscriptController?.utterances
                    .contains { $0.text == LocalLiveMeetingVoxTypeClient.previewText } == false)
            #expect(recorder.liveTranscriptController?.finalEngine == SpeechEngineID.whisper.rawValue)
            #expect(recorder.liveTranscriptController?.finalSpanOutcomes.allSatisfy {
                $0.attestedEngine == SpeechEngineID.whisper.rawValue
                    && $0.attestedModel == SpeechEngineCatalog.englishDefaultModelID
            } == true)
            #expect(try notesStore.load(meetingID: meetingID) == latestNotes)
            #expect(
                try String(
                    contentsOf: notesStore.notesURL(for: meetingID),
                    encoding: .utf8
                ) == latestNotes)
            let storedMeeting = try meetingStore.load(meetingID)
            #expect(
                storedMeeting.utterances.map(\.text) == [LocalLiveMeetingVoxTypeClient.finalText])

            let upload = MeetingUploadController(
                meetingStore: meetingStore,
                notesStore: notesStore,
                analysisStore: FileMeetingAnalysisStore(rootURL: fixture.meetings),
                uploadStore: FileMeetingUploadStore(rootURL: fixture.meetings),
                api: localClient,
                sleep: { _ in }
            )
            await upload.uploadAfterFinalTranscriptPersistence(meetingID: meetingID)
            #expect(upload.uploadState == .delivered)
            let meetingCapture = try fixture.lastLocalCapture()
            let markdown = try #require(meetingCapture["text"] as? String)
            let notesIndex = try #require(markdown.range(of: "## Notes")?.lowerBound)
            let transcriptIndex = try #require(markdown.range(of: "## Transcript")?.lowerBound)
            #expect(notesIndex < transcriptIndex)
            #expect(markdown.contains(latestNotes))
            #expect(markdown.contains(LocalLiveMeetingVoxTypeClient.finalText))
            #expect(!markdown.contains(LocalLiveMeetingVoxTypeClient.previewText))

            meeting.resetCompletedMeeting()
            await meeting.startVoiceNote()
            #expect(meeting.currentMeeting?.recordingKind == .voiceNote)
            #expect(meeting.state == .recording)
            #expect(graph.meetingLivePanel.isPresented)
            #expect(graph.meetingLivePanel.panel === originalPanel)
            #expect(graph.meetingLivePanel.recordingKind == .voiceNote)
            #expect(
                graph.meetingLiveDashboard.transcriptController
                    === recorder.liveTranscriptController)

            let selectedNote = "Selected text remains a local note."
            let noteCapture = CaptureController(
                api: localClient, defaults: defaults, sleep: { _ in })
            let noteAdaptive = AdaptiveCaptureController(
                captureController: noteCapture,
                selectedTextReader: LocalLiveSelectedTextReader(selectedNote),
                resultPresenter: LocalLiveCaptureResultPresenter()
            )
            await noteAdaptive.capture(from: nil)
            await noteCapture.waitForMonitoring()
            let noteEnvelope = try fixture.lastLocalCapture()
            #expect(noteEnvelope["type"] as? String == "note")
            #expect(noteEnvelope["text"] as? String == selectedNote)

            let selectedLink = "https://example.com/local-meeting"
            let linkCapture = CaptureController(
                api: localClient, defaults: defaults, sleep: { _ in })
            let linkAdaptive = AdaptiveCaptureController(
                captureController: linkCapture,
                selectedTextReader: LocalLiveSelectedTextReader(selectedLink),
                resultPresenter: LocalLiveCaptureResultPresenter()
            )
            await linkAdaptive.capture(from: nil)
            await linkCapture.waitForMonitoring()
            let linkEnvelope = try fixture.lastLocalCapture()
            #expect(linkEnvelope["url"] as? String == selectedLink)
            #expect(linkEnvelope["type"] as? String == "article")
            #expect(QuickCaptureMode.allCases == [.note, .link])

            try assertLocalOnlyDistribution(fixture: fixture)
        }

        @Test
        func modelIdentityMismatchBlocksRecordingBeforeAudioStarts() async throws {
            let fixture = try LocalLiveMeetingFixture()
            defer { fixture.remove() }
            let recorder = try LocalLiveMeetingRecorder(
                root: fixture.meetings,
                meetingStore: MeetingStore(rootURL: fixture.meetings)
            )
            let controller = MeetingController(
                detector: LocalLiveMeetingDetector(),
                recorder: recorder,
                speechEngine: "whisper",
                speechModel: "large-v3",
                modelAttester: LocalLiveMeetingModelAttester(result: .failure(
                    VoxTypeModelAttestationError.modelMismatch(
                        requested: "large-v3",
                        effective: "large-v3-turbo"
                    )
                ))
            )

            await controller.startRecording(application: nil)

            #expect(controller.state == .failed)
            #expect(controller.currentMeeting == nil)
            #expect(recorder.startCount == 0)
            guard case .speechModelUnavailable(let message) = controller.failure else {
                Issue.record("Expected a visible model-attestation failure")
                return
            }
            #expect(message.contains("large-v3-turbo"))
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

        private func assertLocalOnlyDistribution(fixture: LocalLiveMeetingFixture) throws {
            let fileManager = FileManager.default
            let removedProducts = [
                "apps/brain-agent",
                "apps/brain-clipper",
                "apps/gmail-connector",
                "apps/telegram-bot",
                "gateway",
                "remote",
                "site",
                "integrations/bookmarklet.js",
                "integrations/capture-everywhere.md",
                "apps/brain-menu/Sources/BrainMenu/Core/BrainAPIClient.swift",
                "apps/brain-menu/Sources/BrainMenu/Core/BrainAPIModels.swift",
                "apps/brain-menu/Sources/BrainMenu/Gmail/GmailConnectionController.swift",
                "apps/brain-menu/Sources/BrainMenu/Knowledge/RemoteKnowledgeStore.swift",
                "apps/brain-menu/Sources/BrainMenu/Operations/RemoteBrainController.swift",
                "apps/brain-menu/Sources/BrainMenu/Security/DeviceCredentialStore.swift",
                "apps/brain-menu/Sources/BrainMenu/Views/ActionsView.swift",
                "apps/brain-menu/Sources/BrainMenu/Views/MCPConnectionView.swift",
                "apps/brain-menu/Sources/BrainMenu/Views/MacMiniView.swift",
            ]
            for path in removedProducts {
                #expect(
                    !fileManager.fileExists(
                        atPath: fixture.repositoryRoot
                            .appendingPathComponent(path).path))
            }

            let package = try String(
                contentsOf: fixture.packageRoot.appendingPathComponent("Package.swift"),
                encoding: .utf8
            )
            #expect(!package.contains(".package("))
            let runtime = try String(
                contentsOf: fixture.packageRoot
                    .appendingPathComponent("Sources/BrainMenu/Core/BrainRuntime.swift"),
                encoding: .utf8
            )
            #expect(runtime.contains("LocalBrainClient"))
            #expect(!runtime.contains("URLSession"))
            #expect(!runtime.contains("baseURL"))
            #expect(!runtime.contains("bearer"))
            let setup = try String(
                contentsOf: fixture.packageRoot
                    .appendingPathComponent("Sources/BrainMenu/Views/BrainSetupView.swift"),
                encoding: .utf8
            )
            #expect(!setup.contains("Picker("))
            #expect(!setup.contains("Pair Brain"))
            #expect(!setup.contains("Remote Brain"))
        }
    }
}

@MainActor
private final class LocalLiveMeetingRecorder: MeetingRecording {
    private let root: URL
    private let meetingStore: MeetingStore
    private let transcript: LiveTranscriptController
    private var request: MeetingRecordingRequest?
    private var writer: MeetingAudioWriter?
    private var transcriptHandler: (@MainActor @Sendable (LiveTranscriptController?) -> Void)?
    private var notesFlushHandler: (@MainActor @Sendable () async -> Void)?

    private(set) var stopCount = 0
    private(set) var startCount = 0
    var liveTranscriptController: LiveTranscriptController? { transcript }

    init(root: URL, meetingStore: MeetingStore) throws {
        self.root = root
        self.meetingStore = meetingStore
        transcript = LiveTranscriptController(
            service: try LiveTranscriptionService(
                client: LocalLiveMeetingVoxTypeClient(),
                engine: .whisper,
                attestedModel: SpeechEngineCatalog.englishDefaultModelID,
                originHostTimestamp: 100,
                wavDirectory: root.appendingPathComponent("voxtype-live-\(UUID().uuidString)")
            ))
    }

    func setLiveTranscriptControllerHandler(
        _ handler: @escaping @MainActor @Sendable (LiveTranscriptController?) -> Void
    ) {
        transcriptHandler = handler
    }

    func setMeetingNotesFlushHandler(
        _ handler: @escaping @MainActor @Sendable () async -> Void
    ) {
        notesFlushHandler = handler
    }

    func start(_ request: MeetingRecordingRequest) async throws {
        startCount += 1
        self.request = request
        let writer = try MeetingAudioWriter(
            meetingDirectory: root.appendingPathComponent(request.meetingID.uuidString),
            origin: request.startedAt
        )
        self.writer = writer
        transcriptHandler?(transcript)
        let buffer = LocalLiveMeetingRecorder.audioBuffer()
        _ = try writer.append(buffer)
        guard request.recordingKind == .meeting else { return }
        await transcript.append(buffer)
        let pause = LocalLiveMeetingRecorder.audioBuffer(
            hostTimestamp: 110,
            duration: 1.3,
            amplitude: 0
        )
        _ = try writer.append(pause)
        await transcript.append(pause)
        await transcript.waitForPendingPreview()
    }

    func pause(at date: Date) async throws {}
    func resume(with discontinuity: MeetingRecordingDiscontinuity) async throws {}

    func stop(at date: Date) async throws -> MeetingRecord? {
        stopCount += 1
        await notesFlushHandler?()
        let request = try #require(request)
        let capture = try #require(writer).finalize()
        await transcript.stop(capture: capture)
        let completed = MeetingRecord(
            id: request.meetingID,
            title: request.title,
            recordingKind: request.recordingKind,
            titleSource: request.titleSource,
            detectedApplication: request.application?.displayName,
            startedAt: request.startedAt,
            endedAt: date,
            lifecycleState: .completed,
            speechEngine: request.speechModelAttestation?.effectiveSelection.engine.rawValue
                ?? "whisper",
            speechModel: request.speechModelAttestation?.effectiveSelection.modelID
                ?? "large-v3",
            speechModelAttestation: request.speechModelAttestation,
            transcriptionState: .completed
        )
        try meetingStore.save(completed, utterances: transcript.utterances)
        return completed
    }

    func preserveForRecovery(at date: Date, reason: MeetingRecoveryReason) async {}

    private static func audioBuffer(
        hostTimestamp: TimeInterval = 100,
        duration: TimeInterval = 10,
        amplitude: Float = 0.2
    ) -> MeetingAudioSampleBuffer {
        MeetingAudioSampleBuffer(
            source: .microphone,
            sourceTimestamp: hostTimestamp * 7,
            hostTimestamp: hostTimestamp,
            sampleRate: Double(MeetingAudioWriter.sampleRate),
            channelCount: MeetingAudioWriter.channelCount,
            interleavedSamples: (0..<Int(duration * Double(MeetingAudioWriter.sampleRate))).map {
                amplitude == 0 ? 0 : ($0.isMultiple(of: 2) ? amplitude : -amplitude)
            }
        )
    }
}

private extension SpeechEngineSelection {
    static let largeV3 = SpeechEngineSelection(engine: .whisper, modelID: "large-v3")
}

@MainActor
private final class LocalLiveMeetingModelAttester: VoxTypeModelAttesting {
    let result: Result<VoxTypeModelAttestation, Error>

    init(result: Result<VoxTypeModelAttestation, Error>) {
        self.result = result
    }

    func attestCurrentSelection() async throws -> VoxTypeModelAttestation {
        try result.get()
    }
}

private extension VoxTypeModelAttestation {
    static let largeV3 = VoxTypeModelAttestation(
        requestedSelection: .largeV3,
        effectiveSelection: .largeV3,
        verifiedAt: Date(timeIntervalSince1970: 1_784_208_000),
        voxTypeVersion: VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil)
    )
}

private actor LocalLiveMeetingVoxTypeClient: LiveTranscriptionClient {
    static let previewText = "preview-only VoxType client text"
    static let finalText = "authoritative final meeting transcript"

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        wavURL.lastPathComponent.hasPrefix("preview") ? Self.previewText : Self.finalText
    }
}

@MainActor
private final class LocalLiveMeetingDetector: MeetingDetecting {
    func observe(_ observation: MeetingDetectorObservation, at date: Date) -> MeetingDetectorEvent?
    {
        nil
    }
    func beginTracking(_ application: MeetingDetectedApplication?) {}
    func dismiss(_ candidate: MeetingStartCandidate) {}
    func suppressEndSuggestions(until date: Date) {}
    func reset() {}
}

@MainActor
private final class LocalLiveSelectedTextReader: SelectedTextReading {
    private let selectedText: String

    init(_ selectedText: String) {
        self.selectedText = selectedText
    }

    func snapshot(
        from application: QuickCaptureApplicationIdentity?
    ) throws -> SelectedTextSnapshot {
        SelectedTextSnapshot(selectedText: selectedText, windowTitle: "Local document")
    }
}

@MainActor
private final class LocalLiveCaptureResultPresenter: AdaptiveCaptureResultPresenting {
    func present(_ failure: AdaptiveCaptureFailure) {
        Issue.record("Adaptive local capture unexpectedly failed: \(failure)")
    }
}

private struct LocalLiveMeetingFixture {
    let root: URL
    let vault: URL
    let meetings: URL
    let cli: URL
    let defaultsSuite: String

    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    var repositoryRoot: URL {
        packageRoot.deletingLastPathComponent().deletingLastPathComponent()
    }

    init() throws {
        defaultsSuite = "LocalLiveMeetingAcceptanceTests.\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(defaultsSuite, isDirectory: true)
        vault = root.appendingPathComponent("Vault", isDirectory: true)
        meetings = root.appendingPathComponent("Meetings", isDirectory: true)
        cli = root.appendingPathComponent("brain", isDirectory: false)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let script = #"""
            #!/bin/sh
            set -eu
            case "${1:-}" in
              init-data)
                mkdir -p "$BRAIN_DATA_ROOT/inbox" "$BRAIN_DATA_ROOT/notes"
                : > "$BRAIN_DATA_ROOT/.brain-data-root"
                ;;
              status)
                printf '%s\n' '{"schema_version":1,"generated_at":"2026-08-11T12:00:00Z","vault":{"path":"'"$BRAIN_DATA_ROOT"'","state":"clean","dirty_paths":0},"counts":{"inbox":0,"sources":0,"notes":0,"people":0,"projects":0},"last_run":null,"services":[]}'
                ;;
              doctor)
                printf '%s\n' '{"schema_version":1,"generated_at":"2026-08-11T12:00:00Z","overall":"healthy","counts":{"pass":1,"activity":0,"warning":0,"failure":0},"checks":[]}'
                ;;
              ingest)
                cat > "$BRAIN_DATA_ROOT/last-ingest.json"
                ;;
              *)
                printf 'unsupported command\n' >&2
                exit 2
                ;;
            esac
            """#
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: cli.path
        )
    }

    func lastLocalCapture() throws -> [String: Any] {
        let data = try Data(contentsOf: vault.appendingPathComponent("last-ingest.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
