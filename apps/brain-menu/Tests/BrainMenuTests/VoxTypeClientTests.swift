import Foundation
import Testing
@testable import BrainMenu

struct VoxTypeClientTests {
    private let executable = URL(fileURLWithPath: "/safe/bin/voxtype", isDirectory: false)
    private let workingDirectory = URL(
        fileURLWithPath: "/safe/Brain/VoxTypeProcess",
        isDirectory: true
    )

    @Test
    func discoveryUsesSelectionThenFixedLocationsThenNamedPathEntries() throws {
        let selected = URL(fileURLWithPath: "/chosen/voxtype")
        let selectedResolved = URL(fileURLWithPath: "/Cellar/voxtype/1.2.3/bin/voxtype")
        let homebrewResolved = URL(fileURLWithPath: "/opt/homebrew/Cellar/voxtype/bin/voxtype")
        let localResolved = URL(fileURLWithPath: "/usr/local/libexec/voxtype")
        let pathResolved = URL(fileURLWithPath: "/tools/current/voxtype")
        let fileSystem = FakeVoxTypeExecutableFileSystem(executables: [
            selected.path: selectedResolved,
            "/opt/homebrew/bin/voxtype": homebrewResolved,
            "/usr/local/bin/voxtype": localResolved,
            "/tools/bin/voxtype": pathResolved,
        ])
        let discoverer = VoxTypeExecutableDiscoverer(
            fileSystem: fileSystem,
            environment: ["PATH": "relative:/tools/bin:/other/bin"],
            bundledCandidate: nil
        )

        #expect(try discoverer.discover(userSelected: selected) == selectedResolved)
        #expect(try discoverer.discover() == homebrewResolved)

        let pathOnly = VoxTypeExecutableDiscoverer(
            fileSystem: FakeVoxTypeExecutableFileSystem(executables: [
                "/tools/bin/voxtype": pathResolved,
            ]),
            environment: ["PATH": "relative:/tools/bin:/other/bin"],
            bundledCandidate: nil
        )
        #expect(try pathOnly.discover() == pathResolved)
        #expect(fileSystem.queries.first == selected.path)
        #expect(!fileSystem.queries.contains("relative/voxtype"))
    }

    @Test
    func discoveryUsesBundledVoxTypeOnlyAfterStandaloneCandidates() throws {
        let bundled = URL(
            fileURLWithPath: "/Brain.app/Contents/Library/LoginItems/VoxType.app/Contents/MacOS/voxtype"
        )
        let bundledResolved = URL(
            fileURLWithPath: "/Brain.app/Contents/Library/LoginItems/VoxType.app/Contents/MacOS/voxtype"
        )
        let external = URL(fileURLWithPath: "/tools/bin/voxtype")
        let externalResolved = URL(fileURLWithPath: "/tools/cellar/voxtype")
        let withExternal = VoxTypeExecutableDiscoverer(
            fileSystem: FakeVoxTypeExecutableFileSystem(executables: [
                external.path: externalResolved,
                bundled.path: bundledResolved,
            ]),
            environment: ["PATH": "/tools/bin"],
            bundledCandidate: bundled
        )
        #expect(try withExternal.discover() == externalResolved)

        let bundledOnly = VoxTypeExecutableDiscoverer(
            fileSystem: FakeVoxTypeExecutableFileSystem(executables: [
                bundled.path: bundledResolved,
            ]),
            environment: [:],
            bundledCandidate: bundled
        )
        #expect(try bundledOnly.discover() == bundledResolved)
    }

    @Test
    func discoveryRejectsUnsafeUserSelections() {
        let fileSystem = FakeVoxTypeExecutableFileSystem(executables: [
            "/bin/sh": URL(fileURLWithPath: "/bin/sh"),
            "/Applications/voxtype-tray": URL(fileURLWithPath: "/Applications/voxtype-tray"),
            "/tmp/voxtype": URL(fileURLWithPath: "/bin/sh"),
        ])
        let discoverer = VoxTypeExecutableDiscoverer(
            fileSystem: fileSystem,
            environment: [:],
            bundledCandidate: nil
        )

        #expect(throws: VoxTypeDiscoveryError.unsafeUserSelection) {
            try discoverer.discover(userSelected: URL(fileURLWithPath: "/bin/sh"))
        }
        #expect(throws: VoxTypeDiscoveryError.unsafeUserSelection) {
            try discoverer.discover(
                userSelected: URL(fileURLWithPath: "/Applications/voxtype-tray")
            )
        }
        #expect(throws: VoxTypeDiscoveryError.unsafeUserSelection) {
            try discoverer.discover(userSelected: URL(string: "https://example.com/voxtype"))
        }
        #expect(throws: VoxTypeDiscoveryError.unsafeUserSelection) {
            try discoverer.discover(userSelected: URL(fileURLWithPath: "/tmp/voxtype"))
        }
    }

    @Test
    func versionIsParsedAndEveryRequestIsFixedAndSanitized() async throws {
        let runner = FakeVoxTypeProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(stdout: "voxtype 2.4.1-beta.2\n")),
        ])
        let client = makeClient(
            runner: runner,
            environment: [
                "HOME": "/Users/test",
                "LANG": "en_GB.UTF-8",
                "VOXTYPE_TOKEN": "must-not-cross-boundary",
                "AWS_SECRET_ACCESS_KEY": "also-secret",
            ]
        )

        #expect(
            try await client.version()
                == VoxTypeVersion(major: 2, minor: 4, patch: 1, prerelease: "beta.2")
        )
        let request = try #require(await runner.requests.first)
        assertSecureRequest(request, arguments: ["--version"])
        #expect(request.environment == ["HOME": "/Users/test", "LANG": "en_GB.UTF-8"])
    }

    @Test
    func versionRejectsMalformedOrFailedOutputWithoutReflectingIt() async {
        let malformed = FakeVoxTypeProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(stdout: "voxtype rolling-build")),
        ])
        await #expect(throws: VoxTypeClientError.invalidVersion) {
            try await makeClient(runner: malformed).version()
        }

        let secret = "sensitive-version-error"
        let failed = FakeVoxTypeProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(stdout: "", stderr: secret, exitStatus: 2)),
        ])
        do {
            _ = try await makeClient(runner: failed).version()
            Issue.record("Expected version command failure")
        } catch {
            #expect(!String(describing: error).contains(secret))
        }
    }

    @Test
    func hotkeyConfigurationReadsTheActiveVoxTypeShortcutWithoutMutation() async throws {
        let runner = FakeVoxTypeProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(stdout: """
                Current Configuration

                [hotkey]
                  key = "FN"
                  modifiers = ["LEFTCTRL"]
                  mode = PushToTalk

                [audio]
                  device = "default"
                """)),
        ])
        let client = makeClient(runner: runner)

        let hotkey = try await client.hotkeyConfiguration()

        #expect(hotkey == VoxTypeHotkeyConfiguration(
            key: "FN",
            modifiers: ["LEFTCTRL"],
            mode: "PushToTalk"
        ))
        #expect(hotkey.shortcutDescription == "Control+Fn (push-to-talk)")
        assertSecureRequest(
            try #require(await runner.requests.first),
            arguments: ["config"]
        )
    }

    @Test
    func hotkeyConfigurationRejectsMissingOrUnsafeFields() async {
        for output in [
            "[hotkey]\nkey = \"FN\"\nmodifiers = []\n",
            "[hotkey]\nkey = \"FN; open /tmp/nope\"\nmodifiers = []\nmode = Toggle\n",
        ] {
            let runner = FakeVoxTypeProcessRunner(outputs: [
                .success(VoxTypeProcessOutput(stdout: output)),
            ])
            await #expect(throws: VoxTypeClientError.invalidConfiguration) {
                try await makeClient(runner: runner).hotkeyConfiguration()
            }
        }
    }

    @Test
    func statusDecodesEveryDocumentedStateAndBoundedExtendedFields() async throws {
        for state in VoxTypeRuntimeState.allCases {
            let runner = FakeVoxTypeProcessRunner(outputs: [
                .success(
                    VoxTypeProcessOutput(
                        stdout: """
                        {"class":"\(state.rawValue)","model":"small.en","device":"default","backend":"CPU"}
                        """
                    )
                ),
            ])
            let client = makeClient(runner: runner)

            #expect(
                await client.status()
                    == .available(
                        VoxTypeStatusSnapshot(
                            state: state,
                            model: "small.en",
                            device: "default",
                            backend: "CPU"
                        )
                    )
            )
            assertSecureRequest(
                try #require(await runner.requests.first),
                arguments: ["status", "--format", "json", "--extended"]
            )
        }
    }

    @Test
    func malformedUnknownAndOversizedStatusBecomeTypedUnavailableStates() async {
        let tooLong = String(repeating: "x", count: VoxTypeClient.maximumStatusFieldBytes + 1)
        let documents = [
            "not-json",
            #"{"class":"paused"}"#,
            "{\"class\":\"idle\",\"model\":\"\(tooLong)\"}",
        ]

        for document in documents {
            let runner = FakeVoxTypeProcessRunner(outputs: [
                .success(VoxTypeProcessOutput(stdout: document)),
            ])
            #expect(await makeClient(runner: runner).status() == .unavailable(.malformedStatus))
        }

        let oversizedRunner = FakeVoxTypeProcessRunner(outputs: [
            .success(
                VoxTypeProcessOutput(
                    stdout: Data(repeating: 0x20, count: VoxTypeClient.maximumOutputBytes + 1)
                )
            ),
        ])
        #expect(
            await makeClient(runner: oversizedRunner).status()
                == .unavailable(.outputTooLarge)
        )
    }

    @Test
    func statusFailuresAreTypedWithoutExposingStderr() async {
        let timeout = FakeVoxTypeProcessRunner(outputs: [
            .failure(VoxTypeProcessError.timedOut),
        ])
        #expect(await makeClient(runner: timeout).status() == .unavailable(.timedOut))

        let absent = FakeVoxTypeProcessRunner(outputs: [
            .success(
                VoxTypeProcessOutput(
                    stdout: "",
                    stderr: "VOXTYPE_TOKEN=super-secret",
                    exitStatus: 2
                )
            ),
        ])
        let status = await makeClient(runner: absent).status()
        #expect(status == .unavailable(.daemonNotRunning))
        #expect(!String(describing: status).contains("super-secret"))
    }

    @Test
    func statusStreamParsesFragmentedBoundedNDJSONAndRecoversAfterBadLinesAndEOF() async throws {
        let oversized = String(repeating: "x", count: VoxTypeClient.maximumStatusLineBytes + 1)
        let statusRunner = FakeVoxTypeStatusProcessRunner(scripts: [
            .init(chunks: [
                Data("{\"class\":\"rec".utf8),
                Data("ording\",\"model\":\"small.en\",\"ignored\":true}\nnot-json\n".utf8),
                Data("\(oversized)\n{\"class\":\"idle\"}".utf8),
            ]),
        ])
        let client = makeClient(
            runner: FakeVoxTypeProcessRunner(outputs: []),
            statusRunner: statusRunner
        )

        var events: [VoxTypeStatus] = []
        for await event in client.statusEvents() { events.append(event) }

        #expect(events == [
            .available(VoxTypeStatusSnapshot(
                state: .recording,
                model: "small.en",
                device: nil,
                backend: nil
            )),
            .unavailable(.malformedStatus),
            .unavailable(.outputTooLarge),
            .available(VoxTypeStatusSnapshot(
                state: .idle,
                model: nil,
                device: nil,
                backend: nil
            )),
            .unavailable(.daemonNotRunning),
        ])
        let request = try #require(statusRunner.requests.first)
        #expect(request.arguments == [
            "status", "--follow", "--format", "json", "--extended",
        ])
        #expect(request.executableURL == executable)
        #expect(request.currentDirectoryURL == workingDirectory)
        #expect(request.timeout == 0)
    }

    @Test
    func cancellingStatusStreamCancelsItsSingleRunningProcess() async {
        let statusRunner = FakeVoxTypeStatusProcessRunner(scripts: [
            .init(
                chunks: [Data("{\"class\":\"recording\"}\n".utf8)],
                holdsOpen: true
            ),
        ])
        let client = makeClient(
            runner: FakeVoxTypeProcessRunner(outputs: []),
            statusRunner: statusRunner
        )
        let task = Task {
            for await _ in client.statusEvents() {}
        }
        await eventually { statusRunner.startCount == 1 }

        task.cancel()
        await task.value
        await eventually { statusRunner.cancellationCount == 1 }

        #expect(statusRunner.startCount == 1)
        #expect(statusRunner.cancellationCount == 1)
    }

    @Test
    func recordingCommandsFailClosedWhenDaemonIsStoppedOrUnavailable() async {
        for statusOutput in [
            #"{"class":"stopped"}"#,
            "malformed",
        ] {
            let runner = FakeVoxTypeProcessRunner(outputs: [
                .success(VoxTypeProcessOutput(stdout: statusOutput)),
            ])
            let client = makeClient(runner: runner)

            await #expect(throws: VoxTypeClientError.self) {
                try await client.startRecordingForPaste()
            }
            #expect(await runner.requests.count == 1)
            #expect(await runner.requests.first?.arguments == [
                "status", "--format", "json", "--extended",
            ])
        }
    }

    @Test
    func recordingUsesOnlyTheThreeFixedArgumentArrays() async throws {
        let idle = VoxTypeProcessOutput(stdout: #"{"class":"idle"}"#)
        let runner = FakeVoxTypeProcessRunner(outputs: [
            .success(idle), .success(VoxTypeProcessOutput()),
            .success(idle), .success(VoxTypeProcessOutput()),
            .success(idle), .success(VoxTypeProcessOutput()),
        ])
        let client = makeClient(runner: runner)

        try await client.startRecordingForPaste()
        try await client.stopRecordingForPaste()
        try await client.cancelRecording()

        let requests = await runner.requests
        #expect(requests.map(\.arguments) == [
            ["status", "--format", "json", "--extended"],
            ["record", "start", "--paste"],
            ["status", "--format", "json", "--extended"],
            ["record", "stop", "--paste"],
            ["status", "--format", "json", "--extended"],
            ["record", "cancel"],
        ])
        for request in requests {
            assertSecureRequest(request, arguments: request.arguments)
        }
    }

    @Test
    func transcribePassesWavPathAndBoundedEngineAsSeparateArguments() async throws {
        let runner = FakeVoxTypeProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(stdout: " hello from VoxType \n")),
        ])
        let client = makeClient(runner: runner)
        let wav = URL(fileURLWithPath: "/private/tmp/meeting;$(touch nope).wav")

        #expect(try await client.transcribe(wavURL: wav, engine: "parakeet") == "hello from VoxType")
        assertSecureRequest(
            try #require(await runner.requests.first),
            arguments: ["--quiet", "transcribe", wav.path, "--engine", "parakeet"],
            scheduling: .background,
            timeout: VoxTypeClient.transcriptionTimeout
        )
    }

    @Test
    func backgroundSchedulingUsesTheSystemTaskPolicyExecutable() throws {
        let process = Process()
        let request = VoxTypeProcessRequest(
            executableURL: executable,
            arguments: ["--quiet", "transcribe", "/private/tmp/meeting.wav"],
            currentDirectoryURL: workingDirectory,
            standardInput: nil,
            environment: [:],
            timeout: 30,
            maximumOutputBytes: 1_048_576,
            scheduling: .background
        )

        ProcessVoxTypeRunner.configureLaunch(process, request: request)

        #expect(process.executableURL?.path == "/usr/sbin/taskpolicy")
        #expect(FileManager.default.isExecutableFile(atPath: "/usr/sbin/taskpolicy"))
        #expect(process.arguments == [
            "-b",
            "-c", "utility",
            executable.path,
            "--quiet", "transcribe", "/private/tmp/meeting.wav",
        ])
    }

    @Test
    func transcribeClassifiesUnsupportedRequestedEngineWithoutExposingStderr() async throws {
        let secret = "must-not-leak-from-voxtype-stderr"
        let runner = FakeVoxTypeProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(
                stderr: Data("""
                \(secret)
                Error: Parakeet engine requested but voxtype was not compiled with --features parakeet
                """.utf8),
                exitStatus: 1
            )),
        ])
        let client = makeClient(runner: runner)
        let wav = URL(fileURLWithPath: "/private/tmp/unsupported-engine.wav")

        do {
            _ = try await client.transcribe(wavURL: wav, engine: "parakeet")
            Issue.record("Expected unsupported-engine failure")
        } catch let error as VoxTypeUnsupportedEngineError {
            #expect(error.engine == "parakeet")
            #expect(!error.localizedDescription.contains(secret))
        } catch {
            Issue.record("Expected VoxTypeUnsupportedEngineError, got \(type(of: error))")
        }

        assertSecureRequest(
            try #require(await runner.requests.first),
            arguments: ["--quiet", "transcribe", wav.path, "--engine", "parakeet"],
            scheduling: .background,
            timeout: VoxTypeClient.transcriptionTimeout
        )
    }

    @Test
    func transcribeDoesNotClassifyAnUnsupportedMessageForAnotherEngine() async {
        let runner = FakeVoxTypeProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(
                stderr: Data("""
                Parakeet engine requested but voxtype was not compiled with --features parakeet
                """.utf8),
                exitStatus: 7
            )),
        ])
        let client = makeClient(runner: runner)

        await #expect(throws: VoxTypeClientError.commandFailed(
            command: .transcribe,
            exitStatus: 7
        )) {
            try await client.transcribe(
                wavURL: URL(fileURLWithPath: "/private/tmp/whisper.wav"),
                engine: "whisper"
            )
        }
    }

    @Test
    func transcribeRemovesVoxTypeFileAndModelDiagnosticsButPreservesSpeechLines() async throws {
        let runner = FakeVoxTypeProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(stdout: """
                Loading Parakeet model...
                Model ready
                Loading audio file: "/private/tmp/private-meeting.wav"
                Audio format: 16000 Hz, 1 channel(s), Int
                Processing 41406 samples (2.59s)...

                First spoken line.
                Second spoken line.
                """)),
        ])
        let client = makeClient(runner: runner)

        #expect(
            try await client.transcribe(
                wavURL: URL(fileURLWithPath: "/private/tmp/private-meeting.wav"),
                engine: "parakeet"
            ) == "First spoken line.\nSecond spoken line."
        )
    }

    @Test
    func transcriptParserRejectsDiagnosticOnlyOutput() {
        let output = Data("""
            Loading audio file: "/tmp/empty.wav"
            Audio format: 16000 Hz, 1 channel(s), Int
            Processing 16000 samples (1.00s)...

            """.utf8)

        #expect(VoxTypeClient.transcriptText(from: output) == nil)
    }

    @Test
    func transcribeRejectsUnsafeEngineAndNonWavSelectionBeforeRunning() async {
        let runner = FakeVoxTypeProcessRunner(outputs: [])
        let client = makeClient(runner: runner)

        await #expect(throws: VoxTypeClientError.invalidEngine) {
            try await client.transcribe(
                wavURL: URL(fileURLWithPath: "/tmp/audio.wav"),
                engine: "whisper; env"
            )
        }
        await #expect(throws: VoxTypeClientError.invalidAudioFile) {
            try await client.transcribe(
                wavURL: URL(fileURLWithPath: "/tmp/transcript.txt"),
                engine: "whisper"
            )
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test
    func commandFailureRedactsTranscriptStderrAndEnvironmentSecrets() async throws {
        let secret = "secret-transcript-and-token"
        let runner = FakeVoxTypeProcessRunner(outputs: [
            .success(
                VoxTypeProcessOutput(stdout: "", stderr: secret, exitStatus: 9)
            ),
        ])
        let client = makeClient(
            runner: runner,
            environment: ["HOME": "/Users/test", "VOXTYPE_TOKEN": secret]
        )

        do {
            _ = try await client.transcribe(
                wavURL: URL(fileURLWithPath: "/tmp/audio.wav"),
                engine: "whisper"
            )
            Issue.record("Expected transcription failure")
        } catch {
            #expect(!String(describing: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }

        let request = try #require(await runner.requests.first)
        #expect(!request.environment.values.contains(secret))

        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("VoxTypeClient.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("UserDefaults"))
        #expect(!source.contains("Logger("))
        #expect(!source.contains("voxtype-tray"))
        #expect(!source.contains("/bin/sh"))
        #expect(source.contains("NSRunningApplication"))
        #expect(source.contains("NSWorkspace"))
    }

    @Test @MainActor
    func modelActivatorRestartsAndWaitsForExactStatusBeforeSuccess() async throws {
        let selection = SpeechEngineSelection(
            engine: .parakeet,
            modelID: "parakeet-tdt-0.6b-v3"
        )
        let configuration = FakeVoxTypeConfigurationEditor()
        let restarter = FakeVoxTypeApplicationRestarter()
        let statuses = FakeVoxTypeStatusObserver(events: [
            .available(VoxTypeStatusSnapshot(
                state: .idle,
                model: selection.modelID,
                device: nil,
                backend: "ONNX"
            )),
        ])
        let activator = VoxTypeModelActivator(
            configuration: configuration,
            restarter: restarter,
            statuses: statuses,
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )

        try await activator.apply(selection)

        #expect(configuration.applied == [selection])
        #expect(configuration.rollbackCount == 0)
        #expect(restarter.restartCount == 1)
        #expect(statuses.streamCount == 1)
    }

    @Test @MainActor
    func modelActivatorRollsBackLaunchFailureAndIncompatibleStatus() async {
        let requested = SpeechEngineSelection(
            engine: .parakeet,
            modelID: "parakeet-tdt-0.6b-v3"
        )

        let launchConfiguration = FakeVoxTypeConfigurationEditor()
        let launchRestarter = FakeVoxTypeApplicationRestarter(
            outcomes: [.failure(.launchFailed), .success(())]
        )
        let launchActivator = VoxTypeModelActivator(
            configuration: launchConfiguration,
            restarter: launchRestarter,
            statuses: FakeVoxTypeStatusObserver(events: [])
        )
        await #expect(throws: VoxTypeModelApplyError.restart(.launchFailed)) {
            try await launchActivator.apply(requested)
        }
        #expect(launchConfiguration.rollbackCount == 1)
        #expect(launchRestarter.restartCount == 2)

        let statusConfiguration = FakeVoxTypeConfigurationEditor()
        let statusRestarter = FakeVoxTypeApplicationRestarter()
        let statusActivator = VoxTypeModelActivator(
            configuration: statusConfiguration,
            restarter: statusRestarter,
            statuses: FakeVoxTypeStatusObserver(events: [
                .available(VoxTypeStatusSnapshot(
                    state: .idle,
                    model: "small.en",
                    device: nil,
                    backend: nil
                )),
            ])
        )
        await #expect(throws: VoxTypeModelApplyError.incompatibleStatus("small.en")) {
            try await statusActivator.apply(requested)
        }
        #expect(statusConfiguration.rollbackCount == 1)
        #expect(statusRestarter.restartCount == 2)
    }

    @Test @MainActor
    func modelActivatorTimesOutAndCancellationBothRollback() async {
        let requested = SpeechEngineSelection(
            engine: .whisper,
            modelID: SpeechEngineCatalog.multilingualFallbackModelID
        )
        let timeoutConfiguration = FakeVoxTypeConfigurationEditor()
        let timeoutRestarter = FakeVoxTypeApplicationRestarter()
        let timeoutActivator = VoxTypeModelActivator(
            configuration: timeoutConfiguration,
            restarter: timeoutRestarter,
            statuses: FakeVoxTypeStatusObserver(events: [], holdsOpen: true),
            sleep: { _ in }
        )
        await #expect(throws: VoxTypeModelApplyError.timedOut) {
            try await timeoutActivator.apply(requested)
        }
        #expect(timeoutConfiguration.rollbackCount == 1)
        #expect(timeoutRestarter.restartCount == 2)

        let cancellationConfiguration = FakeVoxTypeConfigurationEditor()
        let cancellationRestarter = FakeVoxTypeApplicationRestarter()
        let cancellationStatuses = FakeVoxTypeStatusObserver(events: [], holdsOpen: true)
        let cancellationActivator = VoxTypeModelActivator(
            configuration: cancellationConfiguration,
            restarter: cancellationRestarter,
            statuses: cancellationStatuses,
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        let task = Task { try await cancellationActivator.apply(requested) }
        for _ in 0..<200 where cancellationStatuses.streamCount == 0 {
            await Task.yield()
        }
        #expect(cancellationStatuses.streamCount == 1)
        task.cancel()
        await #expect(throws: VoxTypeModelApplyError.cancelled) { try await task.value }
        #expect(cancellationConfiguration.rollbackCount == 1)
        #expect(cancellationRestarter.restartCount == 2)
    }

    private func makeClient(
        runner: FakeVoxTypeProcessRunner,
        statusRunner: (any VoxTypeStatusProcessRunning)? = nil,
        environment: [String: String] = ["HOME": "/Users/test"]
    ) -> VoxTypeClient {
        VoxTypeClient(
            executableURL: executable,
            runner: runner,
            statusRunner: statusRunner,
            workingDirectoryURL: workingDirectory,
            environment: environment
        )
    }

    private func eventually(
        attempts: Int = 200,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }

    private func assertSecureRequest(
        _ request: VoxTypeProcessRequest,
        arguments: [String],
        scheduling: VoxTypeProcessScheduling = .normal,
        timeout: TimeInterval = VoxTypeClient.commandTimeout
    ) {
        #expect(request.executableURL == executable)
        #expect(request.arguments == arguments)
        #expect(request.currentDirectoryURL == workingDirectory)
        #expect(request.standardInput == nil)
        #expect(request.timeout == timeout)
        #expect(request.maximumOutputBytes == 1_048_576)
        #expect(request.scheduling == scheduling)
        #expect(!request.environment.keys.contains("VOXTYPE_TOKEN"))
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/Speech", isDirectory: true)
    }
}

private final class FakeVoxTypeConfigurationEditor: VoxTypeConfigurationEditing,
    @unchecked Sendable {
    private let lock = NSLock()
    private var recordedApplied: [SpeechEngineSelection] = []
    private var recordedRollbacks = 0

    var applied: [SpeechEngineSelection] { lock.withLock { recordedApplied } }
    var rollbackCount: Int { lock.withLock { recordedRollbacks } }

    func apply(_ selection: SpeechEngineSelection) throws -> VoxTypeConfigurationBackup {
        lock.withLock { recordedApplied.append(selection) }
        return VoxTypeConfigurationBackup(data: Data("previous".utf8), selection: nil)
    }

    func rollback(to backup: VoxTypeConfigurationBackup) throws {
        lock.withLock { recordedRollbacks += 1 }
    }
}

@MainActor
private final class FakeVoxTypeApplicationRestarter: VoxTypeApplicationRestarting {
    private var outcomes: [Result<Void, VoxTypeApplicationRestartError>]
    private(set) var restartCount = 0

    init(outcomes: [Result<Void, VoxTypeApplicationRestartError>] = []) {
        self.outcomes = outcomes
    }

    func restart() async throws {
        restartCount += 1
        if !outcomes.isEmpty { try outcomes.removeFirst().get() }
    }
}

private final class FakeVoxTypeStatusObserver: VoxTypeStatusObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [VoxTypeStatus]
    private let holdsOpen: Bool
    private var recordedStreams = 0
    private var retainedContinuations: [AsyncStream<VoxTypeStatus>.Continuation] = []

    var streamCount: Int { lock.withLock { recordedStreams } }

    init(events: [VoxTypeStatus], holdsOpen: Bool = false) {
        self.events = events
        self.holdsOpen = holdsOpen
    }

    func statusEvents() -> AsyncStream<VoxTypeStatus> {
        lock.withLock { recordedStreams += 1 }
        return AsyncStream { continuation in
            events.forEach { continuation.yield($0) }
            if holdsOpen {
                lock.withLock { retainedContinuations.append(continuation) }
            } else {
                continuation.finish()
            }
        }
    }
}

private struct FakeVoxTypeStatusScript: Sendable {
    let chunks: [Data]
    let holdsOpen: Bool

    init(chunks: [Data], holdsOpen: Bool = false) {
        self.chunks = chunks
        self.holdsOpen = holdsOpen
    }
}

private final class FakeVoxTypeStatusProcessRunner: VoxTypeStatusProcessRunning,
    @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [FakeVoxTypeStatusScript]
    private var recordedRequests: [VoxTypeProcessRequest] = []
    private var recordedCancellations = 0

    var requests: [VoxTypeProcessRequest] { lock.withLock { recordedRequests } }
    var startCount: Int { lock.withLock { recordedRequests.count } }
    var cancellationCount: Int { lock.withLock { recordedCancellations } }

    init(scripts: [FakeVoxTypeStatusScript]) {
        self.scripts = scripts
    }

    func stream(_ request: VoxTypeProcessRequest) -> AsyncThrowingStream<Data, Error> {
        let script = lock.withLock { () -> FakeVoxTypeStatusScript in
            recordedRequests.append(request)
            guard !scripts.isEmpty else { return .init(chunks: []) }
            return scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for chunk in script.chunks { continuation.yield(chunk) }
            if script.holdsOpen {
                continuation.onTermination = { @Sendable [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock { self.recordedCancellations += 1 }
                }
            } else {
                continuation.finish()
            }
        }
    }
}

private final class FakeVoxTypeExecutableFileSystem: VoxTypeExecutableFileSystem, @unchecked Sendable {
    private let executables: [String: URL]
    private let lock = NSLock()
    private var recordedQueries: [String] = []

    var queries: [String] { lock.withLock { recordedQueries } }

    init(executables: [String: URL]) {
        self.executables = executables
    }

    func resolvedRegularExecutable(at candidate: URL) -> URL? {
        lock.withLock { recordedQueries.append(candidate.path) }
        return executables[candidate.path]
    }
}

private actor FakeVoxTypeProcessRunner: VoxTypeProcessRunning {
    private var outputs: [Result<VoxTypeProcessOutput, Error>]
    private(set) var requests: [VoxTypeProcessRequest] = []

    init(outputs: [Result<VoxTypeProcessOutput, Error>]) {
        self.outputs = outputs
    }

    func run(_ request: VoxTypeProcessRequest) async throws -> VoxTypeProcessOutput {
        requests.append(request)
        guard !outputs.isEmpty else { throw VoxTypeProcessError.launchFailed }
        return try outputs.removeFirst().get()
    }
}
