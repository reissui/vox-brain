import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct CLIProviderTests {
    private let objectSchema = Data(#"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}"#.utf8)

    @Test
    func codexUsesSelectedModelSafeArgumentsStandardInputAndEmptyOwnedWorkingDirectory() async throws {
        let runner = RecordingCLIRunner(result: success(#"{"answer":"ok"}"#))
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "codex", in: root)
        let provider = CLIProvider(
            configuration: AIProviderConfiguration(
                provider: .codex,
                executableURL: executable,
                model: "gpt-5.4-mini"
            ),
            runner: runner,
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "Application Support/Brain AI")
        )

        let payload = try await provider.run(prompt: "private prompt through stdin", jsonSchema: objectSchema)
        #expect(String(decoding: payload, as: UTF8.self) == #"{"answer":"ok"}"#)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executableURL == executable.standardizedFileURL)
        #expect(invocation.arguments.prefix(8) == [
            "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
            "--ignore-user-config", "--ignore-rules", "--output-schema",
        ])
        #expect(invocation.arguments.count == 12)
        #expect(invocation.arguments[8].hasSuffix(".json"))
        #expect(invocation.arguments.suffix(3) == ["--model", "gpt-5.4-mini", "-"])
        #expect(invocation.arguments.contains(where: { $0.contains("private prompt") }) == false)
        #expect(invocation.standardInput == Data("private prompt through stdin".utf8))
        #expect(invocation.timeout == 300)
        #expect(invocation.maximumStandardOutputBytes == 1_048_576)
        #expect(invocation.maximumStandardErrorBytes == 1_048_576)
        #expect(runner.workingDirectoryContents == [])
        #expect(invocation.currentDirectoryURL.path.contains("Application Support/Brain AI/Runs"))
    }

    @Test
    func claudeUsesExactSafeArgumentsAndUnwrappedStructuredOutput() async throws {
        let runner = RecordingCLIRunner(result: success(#"{"type":"result","structured_output":{"answer":"ok"}}"#))
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "claude", in: root)
        let provider = CLIProvider(
            configuration: AIProviderConfiguration(
                provider: .claude,
                executableURL: executable,
                model: "claude-sonnet-4-5"
            ),
            runner: runner,
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "owned")
        )

        let payload = try await provider.run(prompt: "stdin only", jsonSchema: objectSchema)
        #expect(String(decoding: payload, as: UTF8.self) == #"{"answer":"ok"}"#)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.arguments == [
            "-p", "--safe-mode", "--tools", "", "--no-session-persistence",
            "--output-format", "json", "--json-schema", String(decoding: objectSchema, as: UTF8.self),
            "--model", "claude-sonnet-4-5",
        ])
        #expect(invocation.standardInput == Data("stdin only".utf8))
        #expect(runner.workingDirectoryContents == [])
    }

    @Test
    func advancedRunsExecutableDirectlyWithoutShellOrPromptSubstitution() async throws {
        let shellText = "; touch /tmp/brain-must-not-exist && echo {{prompt}}"
        let runner = RecordingCLIRunner(result: success(#"{"answer":"ok"}"#))
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "custom-ai", in: root)
        let provider = CLIProvider(
            configuration: AIProviderConfiguration(
                provider: .advanced,
                executableURL: executable,
                arguments: ["--literal", shellText],
                model: "must-not-be-added"
            ),
            runner: runner,
            applicationSupportURL: root.appending(path: "owned")
        )

        _ = try await provider.run(prompt: "never put me in argv", jsonSchema: objectSchema)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executableURL.lastPathComponent == "custom-ai")
        #expect(invocation.executableURL.path != "/bin/sh")
        #expect(invocation.arguments == ["--literal", shellText, "--model", "must-not-be-added"])
        #expect(invocation.arguments.contains(where: { $0.contains("never put me") }) == false)
        #expect(invocation.standardInput == Data("never put me in argv".utf8))
    }

    @Test
    func rejectsNonExecutableAndCredentialArguments() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let regularFile = root.appending(path: "not-executable")
        try Data().write(to: regularFile)
        let runner = RecordingCLIRunner(result: success(#"{"answer":"ok"}"#))

        await #expect(throws: AIProviderError.invalidExecutable) {
            _ = try await CLIProvider(
                configuration: AIProviderConfiguration(
                    provider: .advanced,
                    executableURL: regularFile
                ),
                runner: runner,
                applicationSupportURL: root.appending(path: "owned")
            ).run(prompt: "prompt", jsonSchema: objectSchema)
        }
        let executable = try executableFixture(named: "custom-ai", in: root)
        await #expect(throws: AIProviderError.invalidArguments) {
            _ = try await CLIProvider(
                configuration: AIProviderConfiguration(
                    provider: .advanced,
                    executableURL: executable,
                    arguments: ["--api-key", "secret"]
                ),
                runner: runner,
                applicationSupportURL: root.appending(path: "owned-2")
            ).run(prompt: "prompt", jsonSchema: objectSchema)
        }
    }

    @Test
    func validatesModelsBeforeLaunchingAndBoundsTimeouts() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "custom-ai", in: root)
        let runner = RecordingCLIRunner(result: success(#"{"answer":"ok"}"#))
        let invalid = CLIProvider(
            configuration: AIProviderConfiguration(
                provider: .advanced,
                executableURL: executable,
                model: "gpt; rm -rf /",
                timeout: 2_000
            ),
            runner: runner,
            applicationSupportURL: root.appending(path: "owned")
        )

        await #expect(throws: AIProviderError.invalidModel) {
            _ = try await invalid.run(prompt: "prompt", jsonSchema: objectSchema)
        }
        #expect(runner.invocations.isEmpty)
        #expect(AIProviderConfiguration(timeout: 2_000).timeout == 900)
        #expect(AIProviderConfiguration(timeout: 0).timeout == 300)
    }

    @Test
    func customCommandLineParsesQuotesWithoutInvokingAShell() throws {
        let tokens = try AICommandLine.parse(
            #"codex exec --model "gpt-5.4-mini" --label 'meeting notes' -"#
        )

        #expect(tokens == [
            "codex", "exec", "--model", "gpt-5.4-mini", "--label", "meeting notes", "-",
        ])
        #expect(throws: AICommandLineError.unmatchedQuote) {
            try AICommandLine.parse("codex exec 'unfinished")
        }
        #expect(throws: AICommandLineError.trailingEscape) {
            try AICommandLine.parse("codex exec \\")
        }
        #expect(throws: AICommandLineError.empty) {
            try AICommandLine.parse("   ")
        }
    }

    @Test
    func testConnectionDistinguishesEveryRequiredStateWithFixedPrompt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "codex", in: root)

        let readyRunner = RecordingCLIRunner(result: success(#"{"status":"ready"}"#))
        let ready = CLIProvider(
            configuration: AIProviderConfiguration(provider: .codex, executableURL: executable),
            runner: readyRunner,
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "ready")
        )
        #expect(await ready.testConnection() == .ready)
        #expect(readyRunner.invocations.first?.standardInput == Data(CLIProvider.testConnectionPrompt.utf8))
        #expect(CLIProvider.testConnectionPrompt.lowercased().contains("transcript") == false)

        #expect(await CLIProvider(
            configuration: AIProviderConfiguration(provider: .advanced),
            runner: readyRunner,
            environment: ["PATH": ""],
            applicationSupportURL: root.appending(path: "missing")
        ).testConnection() == .missingExecutable)
        #expect(await connectionState(
            executable: executable,
            root: root.appending(path: "auth"),
            result: failure("please log in to Codex")
        ) == .unauthenticated)
        #expect(await connectionState(
            executable: executable,
            root: root.appending(path: "model"),
            result: failure("unknown model selection")
        ) == .invalidModel)

        let timeoutRunner = RecordingCLIRunner(error: CLIProcessError.timedOut)
        #expect(await CLIProvider(
            configuration: AIProviderConfiguration(provider: .codex, executableURL: executable),
            runner: timeoutRunner,
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "timeout")
        ).testConnection() == .timeout)
        #expect(await connectionState(
            executable: executable,
            root: root.appending(path: "schema"),
            result: success(#"{"status":"wrong"}"#)
        ) == .schemaFailure)
    }

    @Test
    func codexResolutionUsesPathThenFixedCandidatesAndDiscoversChatGPTBundle() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pathDirectory = root.appending(path: "path", directoryHint: .isDirectory)
        let homebrewDirectory = root.appending(path: "homebrew", directoryHint: .isDirectory)
        let chatGPTDirectory = root.appending(
            path: "Applications/ChatGPT.app/Contents/Resources",
            directoryHint: .isDirectory
        )
        for directory in [pathDirectory, homebrewDirectory, chatGPTDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let pathCodex = try executableFixture(named: "codex", in: pathDirectory)
        let homebrewCodex = try executableFixture(named: "codex", in: homebrewDirectory)
        let chatGPTCodex = try executableFixture(named: "codex", in: chatGPTDirectory)

        let precedence = AIExecutableResolver(
            environment: ["PATH": pathDirectory.path],
            fixedCandidates: [.codex: [homebrewCodex, chatGPTCodex]]
        )
        #expect(precedence.resolveExecutable(for: .codex) == pathCodex.standardizedFileURL)

        try FileManager.default.removeItem(at: pathCodex)
        try FileManager.default.createDirectory(at: pathCodex, withIntermediateDirectories: false)
        #expect(precedence.resolveExecutable(for: .codex) == homebrewCodex.standardizedFileURL)

        let bundled = AIExecutableResolver(
            environment: ["PATH": ""],
            fixedCandidates: [.codex: [chatGPTCodex]]
        )
        #expect(bundled.resolveExecutable(for: .codex) == chatGPTCodex.standardizedFileURL)
        #expect(bundled.resolveExecutable(for: .advanced) == nil)
    }

    @Test
    func localRunnerEnforcesTimeoutCancellationAndBothOutputBounds() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = LocalCLIProcessRunner()

        let outputFirst = try LocalProcessFixture(
            named: "output-first",
            in: root,
            standardOutputBytes: 129,
            standardErrorBytes: 0
        )
        let outputFirstTask = Task {
            try await runner.run(outputFirst.invocation(timeout: 2, outputLimit: 128))
        }
        try await outputFirst.waitUntilReady()
        try outputFirst.releaseOutput()
        await #expect(throws: CLIProcessError.outputLimitExceeded) {
            _ = try await outputFirstTask.value
        }
        try await outputFirst.expectDescendantExited()

        let fastWriteAndExit = try LocalProcessFixture(
            named: "fast-write-and-exit",
            in: root,
            standardOutputBytes: 129,
            standardErrorBytes: 0
        )
        let fastWriteAndExitTask = Task {
            try await runner.run(fastWriteAndExit.invocation(timeout: 2, outputLimit: 128))
        }
        try await fastWriteAndExit.waitUntilReady()
        try fastWriteAndExit.releaseOutputAndExitImmediately()
        await #expect(throws: CLIProcessError.outputLimitExceeded) {
            _ = try await fastWriteAndExitTask.value
        }
        try await fastWriteAndExit.expectDescendantExited()

        let timeoutFirst = try LocalProcessFixture(
            named: "timeout-first",
            in: root,
            standardOutputBytes: 7,
            standardErrorBytes: 7
        )
        let timeoutFirstTask = Task {
            try await runner.run(timeoutFirst.invocation(timeout: 2, outputLimit: 128))
        }
        try await timeoutFirst.waitUntilReady()
        await #expect(throws: CLIProcessError.timedOut) {
            _ = try await timeoutFirstTask.value
        }
        try await timeoutFirst.expectDescendantExited()

        let cancellation = try LocalProcessFixture(
            named: "cancellation",
            in: root,
            standardOutputBytes: 7,
            standardErrorBytes: 7
        )
        let cancellationTask = Task {
            try await runner.run(cancellation.invocation(timeout: 5, outputLimit: 128))
        }
        try await cancellation.waitUntilReady()
        cancellationTask.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancellationTask.value }
        try await cancellation.expectDescendantExited()

        let standardOutput = try LocalProcessFixture(
            named: "stdout-limit",
            in: root,
            standardOutputBytes: 129,
            standardErrorBytes: 128
        )
        let standardOutputTask = Task {
            try await runner.run(standardOutput.invocation(timeout: 2, outputLimit: 128))
        }
        try await standardOutput.waitUntilReady()
        try standardOutput.releaseOutput()
        await #expect(throws: CLIProcessError.outputLimitExceeded) {
            _ = try await standardOutputTask.value
        }
        try await standardOutput.expectDescendantExited()

        let standardError = try LocalProcessFixture(
            named: "stderr-limit",
            in: root,
            standardOutputBytes: 128,
            standardErrorBytes: 129
        )
        let standardErrorTask = Task {
            try await runner.run(standardError.invocation(timeout: 2, outputLimit: 128))
        }
        try await standardError.waitUntilReady()
        try standardError.releaseOutput()
        await #expect(throws: CLIProcessError.outputLimitExceeded) {
            _ = try await standardErrorTask.value
        }
        try await standardError.expectDescendantExited()

        let multibyteBoundary = try LocalProcessFixture(
            named: "multibyte-boundary",
            in: root,
            standardOutputBytes: 7,
            standardErrorBytes: 5
        )
        let multibyteTask = Task {
            try await runner.run(multibyteBoundary.invocation(timeout: 2, outputLimit: 7))
        }
        try await multibyteBoundary.waitUntilReady()
        try multibyteBoundary.releaseOutputAndExit()
        try await multibyteBoundary.waitUntilOutputWasWritten()
        let multibyteResult = try await multibyteTask.value
        #expect(multibyteResult.standardOutput.count == 7)
        #expect(multibyteResult.standardError.count == 5)
        #expect(String(decoding: multibyteResult.standardOutput, as: UTF8.self).isEmpty == false)
        try await multibyteBoundary.expectDescendantExited()

        let executable = try executableFixture(named: "codex", in: root)
        let mappedOutputError = CLIProvider(
            configuration: AIProviderConfiguration(provider: .codex, executableURL: executable),
            runner: RecordingCLIRunner(error: CLIProcessError.outputLimitExceeded),
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "mapped-output")
        )
        await #expect(throws: AIProviderError.outputTooLarge) {
            _ = try await mappedOutputError.run(prompt: "secret", jsonSchema: objectSchema)
        }
        let mappedTimeoutError = CLIProvider(
            configuration: AIProviderConfiguration(provider: .codex, executableURL: executable),
            runner: RecordingCLIRunner(error: CLIProcessError.timedOut),
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "mapped-timeout")
        )
        await #expect(throws: AIProviderError.timedOut) {
            _ = try await mappedTimeoutError.run(prompt: "secret", jsonSchema: objectSchema)
        }
    }

    @Test
    func rejectsInvalidJSONAndSchemaMismatches() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "codex", in: root)
        for output in ["not json", #"{"answer":7}"#, #"{"answer":"ok","extra":true}"#] {
            let provider = CLIProvider(
                configuration: AIProviderConfiguration(provider: .codex, executableURL: executable),
                runner: RecordingCLIRunner(result: success(output)),
                environment: ["PATH": root.path],
                applicationSupportURL: root.appending(path: UUID().uuidString)
            )
            await #expect(throws: AIProviderError.schemaFailure) {
                _ = try await provider.run(prompt: "prompt", jsonSchema: objectSchema)
            }
        }
    }

    @Test
    func integerSchemaDistinguishesOneFromBooleanTrue() async throws {
        let schema = Data(#"{"type":"object","properties":{"version":{"type":"integer","const":1}},"required":["version"],"additionalProperties":false}"#.utf8)
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try executableFixture(named: "codex", in: root)

        let integerProvider = CLIProvider(
            configuration: AIProviderConfiguration(provider: .codex),
            runner: RecordingCLIRunner(result: success(#"{"version":1}"#)),
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "integer")
        )
        let payload = try await integerProvider.run(prompt: "prompt", jsonSchema: schema)
        #expect(String(decoding: payload, as: UTF8.self) == #"{"version":1}"#)

        let booleanProvider = CLIProvider(
            configuration: AIProviderConfiguration(provider: .codex),
            runner: RecordingCLIRunner(result: success(#"{"version":true}"#)),
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "boolean")
        )
        await #expect(throws: AIProviderError.schemaFailure) {
            _ = try await booleanProvider.run(prompt: "prompt", jsonSchema: schema)
        }
    }

    @Test
    func errorsNeverReflectProviderOutputPromptModelOrArguments() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "codex", in: root)
        let secret = "super-secret-transcript-value"
        let provider = CLIProvider(
            configuration: AIProviderConfiguration(
                provider: .codex,
                executableURL: executable,
                model: "safe-model"
            ),
            runner: RecordingCLIRunner(result: failure("provider stderr \(secret)")),
            environment: ["PATH": root.path],
            applicationSupportURL: root.appending(path: "owned")
        )

        do {
            _ = try await provider.run(prompt: secret, jsonSchema: objectSchema)
            Issue.record("Expected provider failure")
        } catch {
            let rendered = error.localizedDescription
            #expect(rendered.contains(secret) == false)
            #expect(rendered.contains("provider stderr") == false)
            #expect(rendered.contains("safe-model") == false)
            #expect(rendered.contains(executable.path) == false)
        }
    }

    @Test
    func settingsPersistOnlyApprovedCredentialFreeFieldsUsingBookmark() throws {
        let suite = "CLIProviderTests.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "custom-ai", in: root)
        let store = AISettingsStore(defaults: defaults)
        let settings = AIProviderConfiguration(
            provider: .advanced,
            executableURL: executable,
            arguments: ["--format", "json"],
            model: "custom-model",
            timeout: 1_200,
            contextChoice: .plain
        )

        try store.save(settings)
        let loaded = store.load()
        #expect(loaded.provider == .advanced)
        #expect(loaded.executableURL?.standardizedFileURL == executable.standardizedFileURL)
        #expect(loaded.arguments == ["--format", "json"])
        #expect(loaded.model == "custom-model")
        #expect(loaded.timeout == 900)
        #expect(loaded.contextChoice == .plain)

        let persisted = try #require(defaults.data(forKey: AISettingsStore.defaultsKey))
        let rendered = String(decoding: persisted, as: UTF8.self).lowercased()
        for forbidden in ["token", "prompt", "transcript", "stdout", "stderr"] {
            #expect(rendered.contains(forbidden) == false)
        }
        let persistedKeys = defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []
        #expect(Set(persistedKeys) == [AISettingsStore.defaultsKey])
        #expect(AIProvider.providerNote.contains("Transcript text is sent"))
        #expect(AIProvider.providerNote.contains("billing/credits apply"))

        #expect(throws: AISettingsStoreError.invalidArguments) {
            try store.save(AIProviderConfiguration(
                provider: .advanced,
                executableURL: executable,
                arguments: ["--token=must-not-persist"]
            ))
        }

        store.clear()
        #expect(defaults.object(forKey: AISettingsStore.defaultsKey) == nil)
    }

    @Test
    func codexPresetPersistsModelButNoExecutableArgumentsOrCredential() throws {
        let suite = "CLIProviderTests.codex-preset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try executableFixture(named: "codex", in: root)
        let store = AISettingsStore(defaults: defaults)

        try store.save(AIProviderConfiguration(
            provider: .codex,
            executableURL: executable,
            arguments: ["--api-key", "must-never-persist"],
            model: "manual-model"
        ))

        let loaded = store.load()
        #expect(loaded.provider == .codex)
        #expect(loaded.executableURL == nil)
        #expect(loaded.arguments.isEmpty)
        #expect(loaded.model == "manual-model")
        let persisted = try #require(defaults.data(forKey: AISettingsStore.defaultsKey))
        let rendered = String(decoding: persisted, as: UTF8.self)
        #expect(rendered.contains("must-never-persist") == false)
        #expect(rendered.contains(executable.path) == false)
        #expect(rendered.contains("manual-model"))
        #expect(defaults.persistentDomain(forName: suite)?.keys.sorted() == [
            AISettingsStore.defaultsKey,
        ])
    }

    private func connectionState(
        executable: URL,
        root: URL,
        result: CLIProcessResult
    ) async -> AIConnectionState {
        await CLIProvider(
            configuration: AIProviderConfiguration(provider: .codex, executableURL: executable),
            runner: RecordingCLIRunner(result: result),
            environment: ["PATH": executable.deletingLastPathComponent().path],
            applicationSupportURL: root
        ).testConnection()
    }

    private func success(_ output: String) -> CLIProcessResult {
        CLIProcessResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            exitStatus: 0
        )
    }

    private func failure(_ standardError: String) -> CLIProcessResult {
        CLIProcessResult(
            standardOutput: Data(),
            standardError: Data(standardError.utf8),
            exitStatus: 1
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CLIProviderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executableFixture(named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
        return url
    }
}

private final class LocalProcessFixture: @unchecked Sendable {
    private static let helper = #"""
#!/usr/bin/python3
import os
import signal
import subprocess
import sys

if len(sys.argv) == 2 and sys.argv[1] == "--child":
    signal.pause()
    raise SystemExit(0)

control_path, events_path, pid_path = sys.argv[1:4]
stdout_count, stderr_count = map(int, sys.argv[4:6])
child = subprocess.Popen([sys.executable, __file__, "--child"])
with open(pid_path, "w") as pid_file:
    pid_file.write(str(child.pid))

control = open(control_path, "rb", buffering=0)
events = open(events_path, "wb", buffering=0)
events.write(b"R")
while True:
    command = control.read(1)
    if command == b"O":
        payload = "🙂".encode("utf-8")
        os.write(1, (payload * ((stdout_count + 3) // 4))[:stdout_count])
        os.write(2, (payload * ((stderr_count + 3) // 4))[:stderr_count])
        events.write(b"W")
    elif command == b"F":
        payload = "🙂".encode("utf-8")
        os.write(1, (payload * ((stdout_count + 3) // 4))[:stdout_count])
        os.write(2, (payload * ((stderr_count + 3) // 4))[:stderr_count])
        child.kill()
        child.wait()
        raise SystemExit(0)
    elif command == b"E":
        child.kill()
        child.wait()
        events.write(b"X")
        raise SystemExit(0)
    elif not command:
        raise SystemExit(1)
"""#

    private let executableURL: URL
    private let directory: URL
    private let controlHandle: FileHandle
    private let eventsHandle: FileHandle
    private let descendantPIDURL: URL
    private let standardOutputBytes: Int
    private let standardErrorBytes: Int

    init(
        named name: String,
        in root: URL,
        standardOutputBytes: Int,
        standardErrorBytes: Int
    ) throws {
        directory = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executableURL = directory.appending(path: "finite-process-fixture.py")
        let controlURL = directory.appending(path: "control.fifo")
        let eventsURL = directory.appending(path: "events.fifo")
        descendantPIDURL = directory.appending(path: "descendant.pid")
        self.standardOutputBytes = standardOutputBytes
        self.standardErrorBytes = standardErrorBytes

        try Data(Self.helper.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executableURL.path
        )
        guard Darwin.mkfifo(controlURL.path, 0o600) == 0,
              Darwin.mkfifo(eventsURL.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let controlDescriptor = Darwin.open(controlURL.path, O_RDWR)
        let eventsDescriptor = Darwin.open(eventsURL.path, O_RDWR)
        guard controlDescriptor >= 0, eventsDescriptor >= 0 else {
            if controlDescriptor >= 0 { Darwin.close(controlDescriptor) }
            if eventsDescriptor >= 0 { Darwin.close(eventsDescriptor) }
            throw CocoaError(.fileReadUnknown)
        }
        controlHandle = FileHandle(fileDescriptor: controlDescriptor, closeOnDealloc: true)
        eventsHandle = FileHandle(fileDescriptor: eventsDescriptor, closeOnDealloc: true)
    }

    deinit {
        try? controlHandle.close()
        try? eventsHandle.close()
    }

    func invocation(timeout: TimeInterval, outputLimit: Int) -> CLIInvocation {
        CLIInvocation(
            executableURL: executableURL,
            arguments: [
                directory.appending(path: "control.fifo").path,
                directory.appending(path: "events.fifo").path,
                descendantPIDURL.path,
                String(standardOutputBytes),
                String(standardErrorBytes),
            ],
            standardInput: Data(),
            currentDirectoryURL: directory,
            timeout: timeout,
            maximumStandardOutputBytes: outputLimit,
            maximumStandardErrorBytes: outputLimit
        )
    }

    func waitUntilReady() async throws {
        try await expectEvent(ascii: 82)
    }

    func waitUntilOutputWasWritten() async throws {
        try await expectEvent(ascii: 87)
    }

    func releaseOutput() throws {
        try controlHandle.write(contentsOf: Data([79]))
    }

    func releaseExit() throws {
        try controlHandle.write(contentsOf: Data([69]))
    }

    func releaseOutputAndExit() throws {
        try controlHandle.write(contentsOf: Data([79, 69]))
    }

    func releaseOutputAndExitImmediately() throws {
        try controlHandle.write(contentsOf: Data([70]))
    }

    func expectDescendantExited() async throws {
        let pidData = try Data(contentsOf: descendantPIDURL)
        let pid = try #require(pid_t(String(decoding: pidData, as: UTF8.self)))
        for _ in 0..<10_000 {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
            await Task.yield()
        }
        Issue.record("Fixture descendant \(pid) survived process-group termination")
    }

    private func expectEvent(ascii: UInt8) async throws {
        let handle = eventsHandle
        let data = try await Task.detached {
            try handle.read(upToCount: 1) ?? Data()
        }.value
        #expect(data == Data([ascii]))
    }
}

private final class RecordingCLIRunner: CLIProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: CLIProcessResult?
    private let error: (any Error)?
    private var recordedInvocations: [CLIInvocation] = []
    private var recordedWorkingDirectoryContents: [String] = []

    init(result: CLIProcessResult) {
        self.result = result
        error = nil
    }

    init(error: any Error) {
        result = nil
        self.error = error
    }

    var invocations: [CLIInvocation] {
        lock.withLock { recordedInvocations }
    }

    var workingDirectoryContents: [String] {
        lock.withLock { recordedWorkingDirectoryContents }
    }

    func run(_ invocation: CLIInvocation) async throws -> CLIProcessResult {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: invocation.currentDirectoryURL.path
        )) ?? ["<missing>"]
        lock.withLock {
            recordedInvocations.append(invocation)
            recordedWorkingDirectoryContents = contents
        }
        if let error { throw error }
        return result ?? CLIProcessResult(
            standardOutput: Data(),
            standardError: Data(),
            exitStatus: 0
        )
    }
}
