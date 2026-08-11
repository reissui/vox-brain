import Darwin
import CoreFoundation
import Foundation

struct CLIInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let standardInput: Data
    let currentDirectoryURL: URL
    let timeout: TimeInterval
    let maximumStandardOutputBytes: Int
    let maximumStandardErrorBytes: Int
}

struct CLIProcessResult: Equatable, Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitStatus: Int32
}

protocol CLIProcessRunning: Sendable {
    func run(_ invocation: CLIInvocation) async throws -> CLIProcessResult
}

protocol AIExecutableResolving: Sendable {
    func resolveExecutable(for provider: AIProvider) -> URL?
    func resolveExecutable(named name: String) -> URL?
}

extension AIExecutableResolving {
    func resolveExecutable(named name: String) -> URL? {
        guard let provider = AIProvider.allCases.first(where: {
            $0.defaultExecutableName == name
        }) else {
            return nil
        }
        return resolveExecutable(for: provider)
    }
}

struct AIExecutableResolver: AIExecutableResolving, @unchecked Sendable {
    static let defaultFixedCandidates: [AIProvider: [URL]] = [
        .codex: [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        ],
        .claude: [
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ],
    ]

    private let fileManager: FileManager
    private let environment: [String: String]
    private let fixedCandidates: [AIProvider: [URL]]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fixedCandidates: [AIProvider: [URL]] = Self.defaultFixedCandidates
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.fixedCandidates = fixedCandidates
    }

    func resolveExecutable(for provider: AIProvider) -> URL? {
        guard let executableName = provider.defaultExecutableName else { return nil }
        return resolveExecutable(named: executableName)
    }

    func resolveExecutable(named executableName: String) -> URL? {
        guard !executableName.isEmpty,
              !executableName.contains("/"),
              executableName != ".",
              executableName != ".." else {
            return nil
        }
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appending(path: executableName, directoryHint: .notDirectory)
            }
        let matchingFixedCandidates = AIProvider.allCases
            .filter { $0.defaultExecutableName == executableName }
            .flatMap { fixedCandidates[$0] ?? [] }
        var visited = Set<String>()
        for candidate in pathCandidates + matchingFixedCandidates {
            let standardized = candidate.standardizedFileURL
            guard visited.insert(standardized.path).inserted else { continue }
            guard let values = try? standardized.resourceValues(forKeys: [
                .isRegularFileKey, .isExecutableKey,
            ]), values.isRegularFile == true,
            values.isExecutable == true,
            fileManager.isExecutableFile(atPath: standardized.path) else {
                continue
            }
            return standardized
        }
        return nil
    }
}

enum CLIProcessError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputLimitExceeded
}

final class LocalCLIProcessRunner: CLIProcessRunning {
    private enum TerminalCause: Sendable {
        case exited(Int32)
        case outputLimitExceeded
        case timedOut
        case cancelled
        case launchFailed
    }

    private final class TerminalCauseArbiter: @unchecked Sendable {
        private let lock = NSLock()
        private let events: AsyncStream<TerminalCause>
        private let continuation: AsyncStream<TerminalCause>.Continuation
        private var cause: TerminalCause?
        private var processGroup: pid_t?
        private var handles: [FileHandle] = []

        init() {
            (events, continuation) = AsyncStream.makeStream(of: TerminalCause.self)
        }

        func register(processGroup: pid_t, handles: [FileHandle]) {
            let shouldTerminate = lock.withLock {
                self.processGroup = processGroup
                self.handles = handles
                return cause.map(Self.requiresTermination) == true
            }
            if shouldTerminate {
                Self.terminate(processGroup: processGroup, handles: handles)
            }
        }

        @discardableResult
        func latch(_ proposedCause: TerminalCause) -> Bool {
            let cleanup: (pid_t?, [FileHandle])? = lock.withLock {
                guard cause == nil else { return nil }
                cause = proposedCause
                if Self.requiresTermination(proposedCause) {
                    return (processGroup, handles)
                }
                return (nil, [])
            }
            guard let cleanup else { return false }

            if let processGroup = cleanup.0 {
                Self.terminate(processGroup: processGroup, handles: cleanup.1)
            } else if Self.requiresTermination(proposedCause) {
                cleanup.1.forEach { try? $0.close() }
            }
            continuation.yield(proposedCause)
            continuation.finish()
            return true
        }

        func next() async -> TerminalCause {
            for await event in events { return event }
            return lock.withLock { cause ?? .launchFailed }
        }

        private static func requiresTermination(_ cause: TerminalCause) -> Bool {
            switch cause {
            case .exited:
                false
            case .outputLimitExceeded, .timedOut, .cancelled, .launchFailed:
                true
            }
        }

        private static func terminate(processGroup: pid_t, handles: [FileHandle]) {
            handles.forEach { try? $0.close() }
            guard processGroup > 0 else { return }
            _ = Darwin.kill(-processGroup, SIGTERM)
            _ = Darwin.kill(-processGroup, SIGKILL)
        }
    }

    private final class FileHandleBox: @unchecked Sendable {
        let handle: FileHandle

        init(_ handle: FileHandle) {
            self.handle = handle
        }
    }

    private enum ReadResult: Sendable {
        case data(Data)
        case outputLimitExceeded
        case failed
    }

    func run(_ invocation: CLIInvocation) async throws -> CLIProcessResult {
        try Task.checkCancellation()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let arbiter = TerminalCauseArbiter()
        let parentHandles = [
            inputPipe.fileHandleForWriting,
            outputPipe.fileHandleForReading,
            errorPipe.fileHandleForReading,
        ]

        guard let processIdentifier = Self.spawn(
            invocation,
            inputPipe: inputPipe,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        ) else {
            arbiter.register(processGroup: 0, handles: parentHandles)
            arbiter.latch(.launchFailed)
            throw CLIProcessError.launchFailed
        }

        arbiter.register(processGroup: processIdentifier, handles: parentHandles)
        let inputBox = FileHandleBox(inputPipe.fileHandleForWriting)
        let outputBox = FileHandleBox(outputPipe.fileHandleForReading)
        let errorBox = FileHandleBox(errorPipe.fileHandleForReading)
        let input = invocation.standardInput

        let inputTask = Self.blockingTask { () -> Bool in
            do {
                try inputBox.handle.write(contentsOf: input)
                try inputBox.handle.close()
                return true
            } catch {
                try? inputBox.handle.close()
                return false
            }
        }
        let outputTask = Self.readTask(
            outputBox,
            limit: invocation.maximumStandardOutputBytes,
            arbiter: arbiter
        )
        let errorTask = Self.readTask(
            errorBox,
            limit: invocation.maximumStandardErrorBytes,
            arbiter: arbiter
        )

        let waitTask = Self.blockingTask {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = Darwin.waitpid(processIdentifier, &status, 0)
            } while result == -1 && errno == EINTR

            if result == processIdentifier {
                arbiter.latch(.exited(Self.exitStatus(from: status)))
            } else {
                arbiter.latch(.launchFailed)
            }
        }

        let timeout = AIProviderConfiguration.boundedTimeout(invocation.timeout)
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: .milliseconds(Int64(timeout * 1_000)))
                arbiter.latch(.timedOut)
            } catch {
                // The winning terminal event cancels this timer. It is not a new cause.
            }
        }

        let cause = await withTaskCancellationHandler {
            await arbiter.next()
        } onCancel: {
            arbiter.latch(.cancelled)
        }
        timeoutTask.cancel()

        let standardOutput = await outputTask.value
        let standardError = await errorTask.value
        _ = await inputTask.value
        await waitTask.value
        parentHandles.forEach { try? $0.close() }

        switch cause {
        case .outputLimitExceeded:
            throw CLIProcessError.outputLimitExceeded
        case .timedOut:
            throw CLIProcessError.timedOut
        case .cancelled:
            throw CancellationError()
        case .launchFailed:
            throw CLIProcessError.launchFailed
        case .exited(let status):
            if case .outputLimitExceeded = standardOutput {
                throw CLIProcessError.outputLimitExceeded
            }
            if case .outputLimitExceeded = standardError {
                throw CLIProcessError.outputLimitExceeded
            }
            guard case .data(let outputData) = standardOutput,
                  case .data(let errorData) = standardError else {
                throw CLIProcessError.launchFailed
            }
            return CLIProcessResult(
                standardOutput: outputData,
                standardError: errorData,
                exitStatus: status
            )
        }
    }

    private static func readTask(
        _ box: FileHandleBox,
        limit: Int,
        arbiter: TerminalCauseArbiter
    ) -> Task<ReadResult, Never> {
        blockingTask {
            var data = Data()
            do {
                while true {
                    let remainingPlusSentinel = max(1, limit - data.count + 1)
                    let readCount = min(64 * 1_024, remainingPlusSentinel)
                    guard let chunk = try box.handle.read(upToCount: readCount), !chunk.isEmpty else {
                        return .data(data)
                    }
                    guard limit >= 0, chunk.count <= limit - data.count else {
                        arbiter.latch(.outputLimitExceeded)
                        return .outputLimitExceeded
                    }
                    data.append(chunk)
                }
            } catch {
                arbiter.latch(.launchFailed)
                return .failed
            }
        }
    }

    /// Foundation file handles and `waitpid` are blocking APIs. Running them
    /// directly in unstructured Swift tasks can exhaust the cooperative
    /// executor on low-core machines before the timeout task gets a chance to
    /// terminate the child process. Dispatch owns a separate blocking-worker
    /// pool, so the async timeout and cancellation path always remains runnable.
    private static func blockingTask<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) -> Task<Value, Never> {
        Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: operation())
                }
            }
        }
    }

    private static func spawn(
        _ invocation: CLIInvocation,
        inputPipe: Pipe,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) -> pid_t? {
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }

        let inputRead = inputPipe.fileHandleForReading.fileDescriptor
        let inputWrite = inputPipe.fileHandleForWriting.fileDescriptor
        let outputRead = outputPipe.fileHandleForReading.fileDescriptor
        let outputWrite = outputPipe.fileHandleForWriting.fileDescriptor
        let errorRead = errorPipe.fileHandleForReading.fileDescriptor
        let errorWrite = errorPipe.fileHandleForWriting.fileDescriptor

        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, inputRead, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, inputRead),
            posix_spawn_file_actions_addclose(&actions, inputWrite),
            posix_spawn_file_actions_addclose(&actions, outputRead),
            posix_spawn_file_actions_addclose(&actions, outputWrite),
            posix_spawn_file_actions_addclose(&actions, errorRead),
            posix_spawn_file_actions_addclose(&actions, errorWrite),
            invocation.currentDirectoryURL.path.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            },
        ]
        guard actionResults.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
              ) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return nil
        }

        let arguments = [invocation.executableURL.path] + invocation.arguments
        let duplicatedArguments = arguments.map { strdup($0) }
        defer { duplicatedArguments.forEach { free($0) } }
        var argv = duplicatedArguments + [nil]
        var processIdentifier: pid_t = 0
        let result = invocation.executableURL.path.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processIdentifier,
                    executablePath,
                    &actions,
                    &attributes,
                    buffer.baseAddress!,
                    environ
                )
            }
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        return result == 0 ? processIdentifier : nil
    }

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        let terminationSignal = waitStatus & 0x7f
        return terminationSignal == 0 ? (waitStatus >> 8) & 0xff : terminationSignal
    }
}

final class CLIProvider: AIProviding, @unchecked Sendable {
    static let maximumOutputBytes = 1_048_576
    static let testConnectionPrompt =
        "Return a JSON object whose status is ready. This is a connection test and contains no private data."

    static let testConnectionSchema = Data(#"{"type":"object","properties":{"status":{"type":"string","const":"ready"}},"required":["status"],"additionalProperties":false}"#.utf8)

    private let configuration: AIProviderConfiguration
    private let runner: any CLIProcessRunning
    private let fileManager: FileManager
    private let executableResolver: any AIExecutableResolving
    private let applicationSupportURL: URL

    init(
        configuration: AIProviderConfiguration,
        runner: any CLIProcessRunning = LocalCLIProcessRunner(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableResolver: (any AIExecutableResolving)? = nil,
        applicationSupportURL: URL? = nil
    ) {
        self.configuration = configuration
        self.runner = runner
        self.fileManager = fileManager
        self.executableResolver = executableResolver ?? AIExecutableResolver(
            fileManager: fileManager,
            environment: environment
        )
        self.applicationSupportURL = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Brain/AI", directoryHint: .isDirectory)
    }

    func run(prompt: String, jsonSchema: Data) async throws -> Data {
        guard configuration.provider != .disabled else { throw AIProviderError.disabled }
        let executableURL = try resolvedExecutableURL()
        let model = try AIProviderValidation.validatedModel(configuration.model)
        if configuration.provider == .advanced {
            try AIProviderValidation.validateAdvancedArguments(configuration.arguments)
        }
        guard Self.isValidJSONSchema(jsonSchema) else { throw AIProviderError.schemaFailure }

        let runID = UUID().uuidString
        let runsRoot = applicationSupportURL.appending(path: "Runs", directoryHint: .isDirectory)
        let schemasRoot = applicationSupportURL.appending(path: "Schemas", directoryHint: .isDirectory)
        let workingDirectory = runsRoot.appending(path: runID, directoryHint: .isDirectory)
        let schemaURL = schemasRoot.appending(path: "\(runID).json")

        do {
            try fileManager.createDirectory(at: runsRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: schemasRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
            try jsonSchema.write(to: schemaURL, options: [.atomic])
        } catch {
            throw AIProviderError.launchFailed
        }
        defer {
            try? fileManager.removeItem(at: workingDirectory)
            try? fileManager.removeItem(at: schemaURL)
        }

        let arguments = arguments(model: model, schemaURL: schemaURL, schema: jsonSchema)
        let invocation = CLIInvocation(
            executableURL: executableURL,
            arguments: arguments,
            standardInput: Data(prompt.utf8),
            currentDirectoryURL: workingDirectory,
            timeout: AIProviderConfiguration.boundedTimeout(configuration.timeout),
            maximumStandardOutputBytes: Self.maximumOutputBytes,
            maximumStandardErrorBytes: Self.maximumOutputBytes
        )

        let result: CLIProcessResult
        do {
            result = try await runner.run(invocation)
        } catch CLIProcessError.timedOut {
            throw AIProviderError.timedOut
        } catch CLIProcessError.outputLimitExceeded {
            throw AIProviderError.outputTooLarge
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIProviderError.launchFailed
        }

        guard result.exitStatus == 0 else {
            throw Self.classifiedFailure(
                status: result.exitStatus,
                standardOutput: result.standardOutput,
                standardError: result.standardError
            )
        }
        return try Self.validatedPayload(from: result.standardOutput, schema: jsonSchema)
    }

    func testConnection() async -> AIConnectionState {
        guard configuration.provider != .disabled else { return .disabled }
        do {
            _ = try await run(
                prompt: Self.testConnectionPrompt,
                jsonSchema: Self.testConnectionSchema
            )
            return .ready
        } catch AIProviderError.missingExecutable, AIProviderError.invalidExecutable {
            return .missingExecutable
        } catch AIProviderError.unauthenticated {
            return .unauthenticated
        } catch AIProviderError.invalidModel {
            return .invalidModel
        } catch AIProviderError.timedOut {
            return .timeout
        } catch {
            return .schemaFailure
        }
    }

    private func resolvedExecutableURL() throws -> URL {
        if configuration.provider == .advanced {
            guard let selected = configuration.executableURL else {
                throw AIProviderError.missingExecutable
            }
            return try validateExecutable(selected)
        }
        guard let resolved = executableResolver.resolveExecutable(for: configuration.provider) else {
            throw AIProviderError.missingExecutable
        }
        return resolved
    }

    private func validateExecutable(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard let values = try? standardized.resourceValues(forKeys: [
            .isRegularFileKey, .isExecutableKey,
        ]), values.isRegularFile == true,
        values.isExecutable == true,
        fileManager.isExecutableFile(atPath: standardized.path) else {
            throw AIProviderError.invalidExecutable
        }
        return standardized
    }

    private func arguments(model: String?, schemaURL: URL, schema: Data) -> [String] {
        var arguments: [String]
        switch configuration.provider {
        case .disabled:
            arguments = []
        case .codex:
            arguments = [
                "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
                "--ignore-user-config", "--ignore-rules", "--output-schema", schemaURL.path,
            ]
        case .claude:
            arguments = [
                "-p", "--safe-mode", "--tools", "", "--no-session-persistence",
                "--output-format", "json", "--json-schema", String(decoding: schema, as: UTF8.self),
            ]
        case .advanced:
            arguments = configuration.arguments
        }
        if let model {
            arguments.append(contentsOf: ["--model", model])
        }
        if configuration.provider == .codex {
            arguments.append("-")
        }
        return arguments
    }

    private static func classifiedFailure(
        status: Int32,
        standardOutput: Data,
        standardError: Data
    ) -> AIProviderError {
        let boundedDiagnostic = standardOutput.prefix(maximumOutputBytes / 2)
            + standardError.prefix(maximumOutputBytes / 2)
        let diagnostic = String(decoding: boundedDiagnostic, as: UTF8.self).lowercased()
        let authenticationMarkers = [
            "unauthenticated", "not authenticated", "not logged in", "login required",
            "please log in", "please login", "not signed in", "please sign in", "unauthorized",
            "authentication required", "missing credentials",
        ]
        if authenticationMarkers.contains(where: diagnostic.contains) {
            return .unauthenticated
        }
        let modelMarkers = ["invalid model", "unknown model", "model not found", "unsupported model"]
        if modelMarkers.contains(where: diagnostic.contains) {
            return .invalidModel
        }
        return .commandFailed(exitStatus: status)
    }

    private static func isValidJSONSchema(_ schema: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: schema),
              object is [String: Any] else { return false }
        return true
    }

    private static func validatedPayload(from output: Data, schema: Data) throws -> Data {
        guard let raw = try? JSONSerialization.jsonObject(with: output),
              let schemaObject = try? JSONSerialization.jsonObject(with: schema) as? [String: Any] else {
            throw AIProviderError.schemaFailure
        }

        let payload: Any
        if let object = raw as? [String: Any], let structured = object["structured_output"] {
            payload = structured
        } else if let object = raw as? [String: Any], let result = object["result"] as? String,
                  let resultData = result.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: resultData) {
            payload = parsed
        } else {
            payload = raw
        }

        guard JSONSchemaValidator.validate(payload, against: schemaObject),
              let normalized = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw AIProviderError.schemaFailure
        }
        return normalized
    }
}

private enum JSONSchemaValidator {
    static func validate(_ value: Any, against schema: [String: Any]) -> Bool {
        if let constant = schema["const"], !jsonEqual(value, constant) { return false }
        if let choices = schema["enum"] as? [Any], !choices.contains(where: { jsonEqual(value, $0) }) {
            return false
        }
        if let type = schema["type"] as? String, !matches(type: type, value: value) { return false }
        if let types = schema["type"] as? [String], !types.contains(where: { matches(type: $0, value: value) }) {
            return false
        }

        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let required = schema["required"] as? [String] ?? []
            guard required.allSatisfy({ object[$0] != nil }) else { return false }
            if schema["additionalProperties"] as? Bool == false,
               object.keys.contains(where: { properties[$0] == nil }) {
                return false
            }
            for (key, propertySchema) in properties {
                guard let member = object[key] else { continue }
                guard let nested = propertySchema as? [String: Any],
                      validate(member, against: nested) else { return false }
            }
        }

        if let array = value as? [Any] {
            if let minimum = schema["minItems"] as? Int, array.count < minimum { return false }
            if let maximum = schema["maxItems"] as? Int, array.count > maximum { return false }
            if let itemSchema = schema["items"] as? [String: Any],
               !array.allSatisfy({ validate($0, against: itemSchema) }) { return false }
        }
        return true
    }

    private static func matches(type: String, value: Any) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return isBoolean(value)
        case "number": return value is NSNumber && !isBoolean(value)
        case "integer":
            guard let number = value as? NSNumber, !isBoolean(value) else { return false }
            return number.doubleValue.rounded() == number.doubleValue
        case "null": return value is NSNull
        default: return false
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func jsonEqual(_ left: Any, _ right: Any) -> Bool {
        (left as? NSObject)?.isEqual(right) == true
    }
}
