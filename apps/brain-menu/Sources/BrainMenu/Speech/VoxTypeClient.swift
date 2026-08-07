import Darwin
import AppKit
import Foundation

protocol VoxTypeProcessRunning: Sendable {
    func run(_ request: VoxTypeProcessRequest) async throws -> VoxTypeProcessOutput
}

protocol VoxTypeStatusProcessRunning: Sendable {
    func stream(_ request: VoxTypeProcessRequest) -> AsyncThrowingStream<Data, Error>
}

protocol VoxTypeStatusObserving: Sendable {
    func statusEvents() -> AsyncStream<VoxTypeStatus>
}

@MainActor
protocol VoxTypeApplicationRestarting: Sendable {
    func restart() async throws
}

@MainActor
protocol VoxTypeModelApplying: Sendable {
    func apply(_ selection: SpeechEngineSelection) async throws
}

protocol VoxTypeControlling: Sendable {
    func version() async throws -> VoxTypeVersion
    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration
    func status() async -> VoxTypeStatus
    func startRecordingForPaste() async throws
    func stopRecordingForPaste() async throws
    func cancelRecording() async throws
    func transcribe(wavURL: URL, engine: String) async throws -> String
}

enum VoxTypeApplicationRestartError: Error, Equatable, LocalizedError, Sendable {
    case applicationMissing
    case terminationFailed
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .applicationMissing:
            "Brain could not find Voxtype.app. Reinstall VoxType, then try again."
        case .terminationFailed:
            "Brain could not stop VoxType. Quit VoxType manually, then try again."
        case .launchFailed:
            "Brain saved the model but could not relaunch VoxType. Open VoxType and try again."
        }
    }
}

@MainActor
struct SystemVoxTypeApplicationRestarter: VoxTypeApplicationRestarting {
    static let bundleIdentifier = "io.voxtype.daemon"

    private let workspace: NSWorkspace
    private let applicationURL: URL?

    init(
        workspace: NSWorkspace = .shared,
        applicationURL: URL? = nil
    ) {
        self.workspace = workspace
        self.applicationURL = applicationURL
    }

    func restart() async throws {
        let running = [
            Self.bundleIdentifier,
            BundledVoxTypeLayout.bundleIdentifier,
        ].flatMap { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        }
        for application in running where !application.isTerminated {
            _ = application.terminate()
        }

        for _ in 0..<30 where running.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        for application in running where !application.isTerminated {
            _ = application.forceTerminate()
        }
        for _ in 0..<10 where running.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard running.allSatisfy(\.isTerminated) else {
            throw VoxTypeApplicationRestartError.terminationFailed
        }

        let bundledApplicationURL = BundledVoxTypeLayout.applicationURL()
        let resolvedURL = applicationURL
            ?? workspace.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
            ?? workspace.urlForApplication(
                withBundleIdentifier: BundledVoxTypeLayout.bundleIdentifier
            )
            ?? (
                FileManager.default.fileExists(atPath: bundledApplicationURL.path)
                    ? bundledApplicationURL
                    : URL(fileURLWithPath: "/Applications/Voxtype.app", isDirectory: true)
            )
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw VoxTypeApplicationRestartError.applicationMissing
        }

        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await workspace.openApplication(
                at: resolvedURL,
                configuration: configuration
            )
        } catch {
            throw VoxTypeApplicationRestartError.launchFailed
        }
    }
}

enum VoxTypeModelApplyError: Error, Equatable, LocalizedError, Sendable {
    case configuration(VoxTypeConfigurationError)
    case restart(VoxTypeApplicationRestartError)
    case statusUnavailable(VoxTypeUnavailableReason)
    case incompatibleStatus(String?)
    case timedOut
    case cancelled
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .configuration(let error):
            error.localizedDescription
        case .restart(let error):
            error.localizedDescription
        case .statusUnavailable:
            "VoxType did not become ready. Start VoxType, then try the model again."
        case .incompatibleStatus(let actual):
            if let actual {
                "VoxType reported model \(actual), so Brain restored the previous model."
            } else {
                "VoxType did not report an active model, so Brain restored the previous model."
            }
        case .timedOut:
            "VoxType did not confirm the model within 15 seconds. Brain restored the previous model."
        case .cancelled:
            "The model change was superseded by a newer choice."
        case .rollbackFailed:
            "Brain could not restore the previous VoxType model. Open VoxType Settings before dictating."
        }
    }
}

/// Applies one catalog selection as a transaction: narrow atomic config edit,
/// app restart, then status-stream confirmation. Any failure restores the
/// prior bytes before returning to the UI.
@MainActor
final class VoxTypeModelActivator: VoxTypeModelApplying {
    static let confirmationTimeout: Duration = .seconds(15)

    private let configuration: any VoxTypeConfigurationEditing
    private let restarter: any VoxTypeApplicationRestarting
    private let statuses: any VoxTypeStatusObserving
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        configuration: any VoxTypeConfigurationEditing,
        restarter: any VoxTypeApplicationRestarting = SystemVoxTypeApplicationRestarter(),
        statuses: any VoxTypeStatusObserving,
        timeout: Duration = VoxTypeModelActivator.confirmationTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.configuration = configuration
        self.restarter = restarter
        self.statuses = statuses
        self.timeout = timeout
        self.sleep = sleep
    }

    func apply(_ selection: SpeechEngineSelection) async throws {
        let backup: VoxTypeConfigurationBackup
        do {
            backup = try configuration.apply(selection)
        } catch let error as VoxTypeConfigurationError {
            throw VoxTypeModelApplyError.configuration(error)
        } catch {
            throw VoxTypeModelApplyError.configuration(.atomicWriteFailed)
        }

        do {
            try Task.checkCancellation()
            try await restarter.restart()
            try Task.checkCancellation()
            try await confirm(selection)
        } catch {
            let reported = Self.typed(error)
            do {
                try configuration.rollback(to: backup)
                try await restarter.restart()
            } catch {
                throw VoxTypeModelApplyError.rollbackFailed
            }
            throw reported
        }
    }

    private func confirm(_ selection: SpeechEngineSelection) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [statuses] in
                for await status in statuses.statusEvents() {
                    try Task.checkCancellation()
                    switch status {
                    case .available(let snapshot):
                        guard snapshot.daemonIsRunning else { continue }
                        guard snapshot.model == selection.modelID else {
                            throw VoxTypeModelApplyError.incompatibleStatus(snapshot.model)
                        }
                        return
                    case .unavailable(let reason):
                        throw VoxTypeModelApplyError.statusUnavailable(reason)
                    }
                }
                try Task.checkCancellation()
                throw VoxTypeModelApplyError.statusUnavailable(.daemonNotRunning)
            }
            group.addTask { [sleep, timeout] in
                try await sleep(timeout)
                throw VoxTypeModelApplyError.timedOut
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static func typed(_ error: Error) -> VoxTypeModelApplyError {
        if let error = error as? VoxTypeModelApplyError { return error }
        if let error = error as? VoxTypeApplicationRestartError { return .restart(error) }
        if error is CancellationError { return .cancelled }
        return .restart(.launchFailed)
    }
}

protocol VoxTypeExecutableFileSystem: Sendable {
    func resolvedRegularExecutable(at candidate: URL) -> URL?
}

struct LocalVoxTypeExecutableFileSystem: VoxTypeExecutableFileSystem {
    func resolvedRegularExecutable(at candidate: URL) -> URL? {
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else { return nil }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }
}

struct VoxTypeExecutableDiscoverer: Sendable {
    static let fixedCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/voxtype", isDirectory: false),
        URL(fileURLWithPath: "/usr/local/bin/voxtype", isDirectory: false),
    ]

    private let fileSystem: any VoxTypeExecutableFileSystem
    private let path: String
    private let bundledCandidate: URL?

    init(
        fileSystem: any VoxTypeExecutableFileSystem = LocalVoxTypeExecutableFileSystem(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledCandidate: URL? = BundledVoxTypeLayout.executableURL()
    ) {
        self.fileSystem = fileSystem
        path = environment["PATH"] ?? ""
        self.bundledCandidate = bundledCandidate
    }

    func discover(userSelected: URL? = nil) throws -> URL? {
        if let userSelected {
            guard isNamedVoxType(userSelected),
                  let resolved = fileSystem.resolvedRegularExecutable(at: userSelected),
                  isNamedVoxType(resolved) else {
                throw VoxTypeDiscoveryError.unsafeUserSelection
            }
            return resolved
        }

        var seen = Set<String>()
        let pathCandidates = path.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent("voxtype", isDirectory: false)
            }

        for candidate in Self.fixedCandidates + pathCandidates + [bundledCandidate].compactMap({ $0 }) {
            let standardized = candidate.standardizedFileURL
            guard seen.insert(standardized.path).inserted,
                  isNamedVoxType(standardized),
                  let resolved = fileSystem.resolvedRegularExecutable(at: standardized),
                  isNamedVoxType(resolved) else {
                continue
            }
            return resolved
        }
        return nil
    }

    private func isNamedVoxType(_ candidate: URL) -> Bool {
        candidate.isFileURL
            && candidate.path.hasPrefix("/")
            && candidate.lastPathComponent == "voxtype"
    }
}

final class ProcessVoxTypeRunner: VoxTypeProcessRunning, VoxTypeStatusProcessRunning {
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var stopped = false

        init(_ process: Process) {
            self.process = process
        }

        func stop() {
            let shouldStop = lock.withLock {
                guard !stopped else { return false }
                stopped = true
                return true
            }
            guard shouldStop, process.isRunning else { return }

            let identifier = process.processIdentifier
            process.terminate()
            if process.isRunning {
                Darwin.kill(identifier, SIGKILL)
            }
        }
    }

    private final class BoundedPipeReader: @unchecked Sendable {
        let pipe: Pipe
        let stream: VoxTypeOutputStream

        init(pipe: Pipe, stream: VoxTypeOutputStream) {
            self.pipe = pipe
            self.stream = stream
        }

        func read(maximumBytes: Int, process: ProcessBox) throws -> Data {
            var data = Data()
            while true {
                let remainingPlusSentinel = max(1, maximumBytes - data.count + 1)
                let count = min(64 * 1_024, remainingPlusSentinel)
                let chunk = try pipe.fileHandleForReading.read(upToCount: count) ?? Data()
                guard !chunk.isEmpty else { return data }
                guard data.count + chunk.count <= maximumBytes else {
                    process.stop()
                    throw VoxTypeProcessError.outputLimitExceeded(stream)
                }
                data.append(chunk)
            }
        }
    }

    private enum Completion: Sendable {
        case exited(Int32)
        case timedOut
        case cancelled
    }

    private final class StreamingProcess: @unchecked Sendable {
        private let process = Process()
        private let stdoutPipe = Pipe()
        private let stderrPipe = Pipe()
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        private var stopped = false
        private var stderrBytes = 0

        func start(
            request: VoxTypeProcessRequest,
            continuation: AsyncThrowingStream<Data, Error>.Continuation
        ) {
            lock.withLock { self.continuation = continuation }
            ProcessVoxTypeRunner.configureLaunch(process, request: request)
            process.currentDirectoryURL = request.currentDirectoryURL
            process.environment = request.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self.lock.withLock { self.continuation }?.yield(data)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let exceeded = self.lock.withLock {
                    self.stderrBytes += data.count
                    return self.stderrBytes > request.maximumOutputBytes
                }
                if exceeded {
                    self.finish(throwing: VoxTypeStatusProcessError.outputTooLarge)
                    self.stop()
                }
            }
            process.terminationHandler = { [weak self] _ in
                self?.finishAfterProcessExit()
            }

            do {
                try process.run()
            } catch {
                finish(throwing: VoxTypeStatusProcessError.launchFailed)
            }
        }

        func stop() {
            let shouldStop = lock.withLock {
                guard !stopped else { return false }
                stopped = true
                return true
            }
            guard shouldStop else { return }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                let identifier = process.processIdentifier
                process.terminate()
                if process.isRunning { Darwin.kill(identifier, SIGKILL) }
            }
            finish()
        }

        private func finishAfterProcessExit() {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                lock.withLock { continuation }?.yield(remaining)
            }
            finish()
        }

        private func finish(throwing error: Error? = nil) {
            let continuation = lock.withLock { () -> AsyncThrowingStream<Data, Error>.Continuation? in
                let value = self.continuation
                self.continuation = nil
                return value
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if let error {
                continuation?.finish(throwing: error)
            } else {
                continuation?.finish()
            }
        }
    }

    func run(_ request: VoxTypeProcessRequest) async throws -> VoxTypeProcessOutput {
        guard request.maximumOutputBytes > 0,
              request.timeout > 0,
              try prepareEmptyWorkingDirectory(request.currentDirectoryURL) else {
            throw VoxTypeProcessError.invalidWorkingDirectory
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let processBox = ProcessBox(process)

        Self.configureLaunch(process, request: request)
        process.currentDirectoryURL = request.currentDirectoryURL
        process.environment = request.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let standardInput = request.standardInput {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            inputPipe.fileHandleForWriting.write(standardInput)
            try? inputPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let terminationStatuses = AsyncStream<Int32> { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.yield(terminatedProcess.terminationStatus)
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw VoxTypeProcessError.launchFailed
        }

        let stdoutReader = BoundedPipeReader(pipe: stdoutPipe, stream: .stdout)
        let stderrReader = BoundedPipeReader(pipe: stderrPipe, stream: .stderr)
        let stdoutTask = Task.detached {
            try stdoutReader.read(
                maximumBytes: request.maximumOutputBytes,
                process: processBox
            )
        }
        let stderrTask = Task.detached {
            try stderrReader.read(
                maximumBytes: request.maximumOutputBytes,
                process: processBox
            )
        }

        let completion = await withTaskGroup(of: Completion.self) { group in
            group.addTask {
                for await status in terminationStatuses { return .exited(status) }
                return .cancelled
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(Int64(request.timeout * 1_000)))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let first = await group.next() ?? .cancelled
            if case .exited = first {
                group.cancelAll()
            } else {
                processBox.stop()
                group.cancelAll()
            }
            return first
        }

        let stdout: Data
        let stderr: Data
        do {
            stdout = try await stdoutTask.value
            stderr = try await stderrTask.value
        } catch {
            processBox.stop()
            throw error
        }

        switch completion {
        case .exited(let exitStatus):
            return VoxTypeProcessOutput(stdout: stdout, stderr: stderr, exitStatus: exitStatus)
        case .timedOut:
            throw VoxTypeProcessError.timedOut
        case .cancelled:
            throw CancellationError()
        }
    }

    func stream(_ request: VoxTypeProcessRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard request.maximumOutputBytes > 0,
                  (try? prepareEmptyWorkingDirectory(request.currentDirectoryURL)) == true else {
                continuation.finish(throwing: VoxTypeProcessError.invalidWorkingDirectory)
                return
            }

            let streamingProcess = StreamingProcess()
            continuation.onTermination = { @Sendable _ in
                streamingProcess.stop()
            }
            streamingProcess.start(request: request, continuation: continuation)
        }
    }

    static func configureLaunch(
        _ process: Process,
        request: VoxTypeProcessRequest
    ) {
        switch request.scheduling {
        case .normal:
            process.executableURL = request.executableURL
            process.arguments = request.arguments
        case .background:
            process.executableURL = URL(
                fileURLWithPath: "/usr/sbin/taskpolicy",
                isDirectory: false
            )
            process.arguments = [
                "-b",
                "-c", "utility",
                request.executableURL.path,
            ] + request.arguments
        }
    }

    private func prepareEmptyWorkingDirectory(_ directory: URL) throws -> Bool {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            guard isDirectory.boolValue,
                  owner == Darwin.geteuid(),
                  permissions.map({ $0 & 0o077 == 0 }) == true,
                  directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL,
                  try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                return false
            }
            return true
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return true
    }
}

private struct UnavailableVoxTypeStatusProcessRunner: VoxTypeStatusProcessRunning {
    func stream(_ request: VoxTypeProcessRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: VoxTypeStatusProcessError.launchFailed)
        }
    }
}

struct VoxTypeClient: VoxTypeControlling, VoxTypeStatusObserving, Sendable {
    static let maximumOutputBytes = 1 * 1_024 * 1_024
    static let commandTimeout: TimeInterval = 30
    static let transcriptionTimeout: TimeInterval = 120
    static let modelInstallTimeout: TimeInterval = 60 * 60
    static let maximumStatusFieldBytes = 256
    static let maximumStatusLineBytes = 16 * 1_024

    let executableURL: URL
    let workingDirectoryURL: URL

    private let runner: any VoxTypeProcessRunning
    private let statusRunner: any VoxTypeStatusProcessRunning
    private let environment: [String: String]

    init(
        executableURL: URL,
        runner: any VoxTypeProcessRunning = ProcessVoxTypeRunner(),
        statusRunner: (any VoxTypeStatusProcessRunning)? = nil,
        workingDirectoryURL: URL = VoxTypeClient.defaultWorkingDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.statusRunner = statusRunner
            ?? (runner as? any VoxTypeStatusProcessRunning)
            ?? UnavailableVoxTypeStatusProcessRunner()
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = Self.sanitizedEnvironment(environment)
    }

    static func discover(
        userSelected: URL? = nil,
        runner: any VoxTypeProcessRunning = ProcessVoxTypeRunner(),
        workingDirectoryURL: URL = VoxTypeClient.defaultWorkingDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> VoxTypeClient? {
        let discoverer = VoxTypeExecutableDiscoverer(environment: environment)
        guard let executable = try discoverer.discover(userSelected: userSelected) else {
            return nil
        }
        return VoxTypeClient(
            executableURL: executable,
            runner: runner,
            workingDirectoryURL: workingDirectoryURL,
            environment: environment
        )
    }

    func version() async throws -> VoxTypeVersion {
        let output = try await executeSuccessful(.version, arguments: ["--version"])
        guard let text = String(data: output.stdout, encoding: .utf8),
              let version = Self.parseVersion(text) else {
            throw VoxTypeClientError.invalidVersion
        }
        return version
    }

    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration {
        let output = try await executeSuccessful(.configuration, arguments: ["config"])
        guard let text = String(data: output.stdout, encoding: .utf8),
              let configuration = Self.parseHotkeyConfiguration(text) else {
            throw VoxTypeClientError.invalidConfiguration
        }
        return configuration
    }

    func status() async -> VoxTypeStatus {
        do {
            let output = try await execute(
                .status,
                arguments: ["status", "--format", "json", "--extended"]
            )
            guard output.exitStatus == 0 else {
                return .unavailable(.daemonNotRunning)
            }
            return Self.decodeStatus(output.stdout)
        } catch VoxTypeClientError.outputTooLarge {
            return .unavailable(.outputTooLarge)
        } catch VoxTypeClientError.timedOut {
            return .unavailable(.timedOut)
        } catch VoxTypeClientError.launchFailed {
            return .unavailable(.launchFailed)
        } catch is CancellationError {
            return .unavailable(.launchFailed)
        } catch {
            return .unavailable(.malformedStatus)
        }
    }

    func statusEvents() -> AsyncStream<VoxTypeStatus> {
        let request = VoxTypeProcessRequest(
            executableURL: executableURL,
            arguments: ["status", "--follow", "--format", "json", "--extended"],
            currentDirectoryURL: workingDirectoryURL,
            standardInput: nil,
            environment: environment,
            timeout: 0,
            maximumOutputBytes: Self.maximumOutputBytes,
            scheduling: .normal
        )

        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                var decoder = VoxTypeStatusNDJSONDecoder(
                    maximumLineBytes: Self.maximumStatusLineBytes,
                    decode: Self.decodeStatus
                )
                do {
                    for try await chunk in statusRunner.stream(request) {
                        try Task.checkCancellation()
                        for status in decoder.append(chunk) {
                            continuation.yield(status)
                        }
                    }
                    for status in decoder.finish() { continuation.yield(status) }
                    if !Task.isCancelled {
                        continuation.yield(.unavailable(.daemonNotRunning))
                    }
                } catch is CancellationError {
                    // Cancellation is an expected app shutdown path.
                } catch VoxTypeStatusProcessError.outputTooLarge,
                        VoxTypeProcessError.outputLimitExceeded {
                    continuation.yield(.unavailable(.outputTooLarge))
                } catch VoxTypeStatusProcessError.launchFailed,
                        VoxTypeProcessError.launchFailed,
                        VoxTypeProcessError.invalidWorkingDirectory {
                    continuation.yield(.unavailable(.launchFailed))
                } catch {
                    continuation.yield(.unavailable(.daemonNotRunning))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func startRecordingForPaste() async throws {
        try await requireDaemon()
        _ = try await executeSuccessful(
            .recordStart,
            arguments: ["record", "start", "--paste"]
        )
    }

    func stopRecordingForPaste() async throws {
        try await requireDaemon()
        _ = try await executeSuccessful(
            .recordStop,
            arguments: ["record", "stop", "--paste"]
        )
    }

    func cancelRecording() async throws {
        try await requireDaemon()
        _ = try await executeSuccessful(
            .recordCancel,
            arguments: ["record", "cancel"]
        )
    }

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        guard Self.isSafeEngine(engine) else { throw VoxTypeClientError.invalidEngine }
        guard wavURL.isFileURL,
              wavURL.path.hasPrefix("/"),
              wavURL.pathExtension.lowercased() == "wav" else {
            throw VoxTypeClientError.invalidAudioFile
        }

        let output = try await executeSuccessful(
            .transcribe,
            arguments: [
                "--quiet",
                "transcribe",
                wavURL.standardizedFileURL.path,
                "--engine",
                engine,
            ],
            timeout: Self.transcriptionTimeout,
            requestedEngine: engine
        )
        guard let transcript = Self.transcriptText(from: output.stdout) else {
            throw VoxTypeClientError.invalidTranscript
        }
        return transcript
    }

    /// VoxType 0.7.5 prints file/model diagnostics to stdout even in quiet
    /// mode. Its final file-transcription boundary is the `Processing …
    /// samples` line followed by a blank line. Keep everything after that
    /// boundary so multi-line speech survives without entering Meetings as
    /// model-loader prose. Future versions that emit only text take the
    /// fallback path unchanged.
    static func transcriptText(from data: Data) -> String? {
        guard var output = String(data: data, encoding: .utf8) else { return nil }
        output = output.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = output.components(separatedBy: "\n")
        if let processing = lines.lastIndex(where: {
            $0.hasPrefix("Processing ") && $0.contains(" samples")
        }), lines[..<processing].contains(where: { $0.hasPrefix("Loading audio file: ") }),
           lines[..<processing].contains(where: { $0.hasPrefix("Audio format: ") }) {
            var firstTranscriptLine = processing + 1
            while firstTranscriptLine < lines.count,
                  lines[firstTranscriptLine].trimmingCharacters(in: .whitespaces).isEmpty {
                firstTranscriptLine += 1
            }
            let transcript = lines[firstTranscriptLine...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? nil : transcript
        }
        let transcript = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : transcript
    }

    func installedModelList() async throws -> String {
        let listOutput = try await executeSuccessful(
            .modelList,
            arguments: ["setup", "model", "--list"]
        )
        let configurationOutput = try await executeSuccessful(
            .configuration,
            arguments: ["config"]
        )
        guard let inventory = String(data: listOutput.stdout, encoding: .utf8),
              let configuration = String(data: configurationOutput.stdout, encoding: .utf8) else {
            throw VoxTypeClientError.invalidModelInventory
        }
        return inventory + "\n" + Self.safeParakeetInventory(from: configuration)
    }

    /// The standard model-list command currently reports Whisper downloads on
    /// macOS. VoxType's resolved configuration separately reports only the
    /// installed Parakeet model IDs. Reduce that output to catalog IDs before
    /// returning it so unrelated configuration (including credentials) never
    /// crosses the inventory boundary.
    private static func safeParakeetInventory(from configuration: String) -> String {
        guard configuration.utf8.count <= maximumOutputBytes else {
            return "Installed Parakeet Models\n=========================\nNo Parakeet models installed."
        }
        var inParakeetSection = false
        var installed = Set<String>()
        for rawLine in configuration.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inParakeetSection = line == "[parakeet]"
                continue
            }
            guard inParakeetSection,
                  line.lowercased().hasPrefix("available models:") else { continue }
            let values = line.dropFirst("available models:".count)
            for value in values.split(whereSeparator: { $0 == "," || $0 == " " }) {
                let id = String(value)
                guard SpeechEngineCatalog.model(id: id)?.engine == .parakeet else { continue }
                installed.insert(id)
            }
        }
        let entries = installed.sorted().compactMap { id -> String? in
            guard let model = SpeechEngineCatalog.model(id: id) else { return nil }
            return "  \(id) (\(model.diskSizeMB) MB) - Installed"
        }
        return "Installed Parakeet Models\n=========================\n"
            + (entries.isEmpty ? "No Parakeet models installed." : entries.joined(separator: "\n"))
    }

    func installModel(id: String) async throws {
        guard SpeechEngineCatalog.model(id: id) != nil else {
            throw VoxTypeClientError.invalidModel
        }
        _ = try await executeSuccessful(
            .modelInstall,
            arguments: ["setup", "--download", "--model", id, "--quiet"],
            timeout: Self.modelInstallTimeout
        )
    }

    private func requireDaemon() async throws {
        let current = await status()
        guard case .available(let snapshot) = current, snapshot.daemonIsRunning else {
            let reason: VoxTypeUnavailableReason
            if case .unavailable(let unavailableReason) = current {
                reason = unavailableReason
            } else {
                reason = .daemonNotRunning
            }
            throw VoxTypeClientError.daemonUnavailable(reason)
        }
    }

    private func executeSuccessful(
        _ command: VoxTypeCommand,
        arguments: [String],
        timeout: TimeInterval = Self.commandTimeout,
        requestedEngine: String? = nil
    ) async throws -> VoxTypeProcessOutput {
        let output = try await execute(command, arguments: arguments, timeout: timeout)
        guard output.exitStatus == 0 else {
            if let requestedEngine,
               Self.stderrReportsUnsupportedEngine(
                   output.stderr,
                   requestedEngine: requestedEngine
               ) {
                throw VoxTypeUnsupportedEngineError(engine: requestedEngine)
            }
            throw VoxTypeClientError.commandFailed(
                command: command,
                exitStatus: output.exitStatus
            )
        }
        return output
    }

    private func execute(
        _ command: VoxTypeCommand,
        arguments: [String],
        timeout: TimeInterval = Self.commandTimeout
    ) async throws -> VoxTypeProcessOutput {
        do {
            let output = try await runner.run(
                VoxTypeProcessRequest(
                    executableURL: executableURL,
                    arguments: arguments,
                    currentDirectoryURL: workingDirectoryURL,
                    standardInput: nil,
                    environment: environment,
                    timeout: timeout,
                    maximumOutputBytes: Self.maximumOutputBytes,
                    scheduling: command == .transcribe ? .background : .normal
                )
            )
            guard output.stdout.count <= Self.maximumOutputBytes,
                  output.stderr.count <= Self.maximumOutputBytes else {
                throw VoxTypeClientError.outputTooLarge
            }
            return output
        } catch let error as VoxTypeClientError {
            throw error
        } catch VoxTypeProcessError.outputLimitExceeded {
            throw VoxTypeClientError.outputTooLarge
        } catch VoxTypeProcessError.timedOut {
            throw VoxTypeClientError.timedOut(command: command)
        } catch VoxTypeProcessError.launchFailed,
                VoxTypeProcessError.invalidWorkingDirectory {
            throw VoxTypeClientError.launchFailed(command: command)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VoxTypeClientError.launchFailed(command: command)
        }
    }

    private static func stderrReportsUnsupportedEngine(
        _ data: Data,
        requestedEngine: String
    ) -> Bool {
        guard data.count <= maximumOutputBytes,
              isSafeEngine(requestedEngine),
              let message = String(data: data, encoding: .utf8) else {
            return false
        }
        let engine = requestedEngine.lowercased()
        let normalized = message.lowercased()
        return normalized.contains("\(engine) engine requested")
            && normalized.contains("voxtype was not compiled")
            && normalized.contains("--features \(engine)")
    }

    static func decodeStatus(_ data: Data) -> VoxTypeStatus {
        struct Document: Decodable {
            let `class`: String
            let model: String?
            let device: String?
            let backend: String?
        }

        guard data.count <= maximumOutputBytes,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              let state = VoxTypeRuntimeState(rawValue: document.class),
              [document.model, document.device, document.backend]
                .compactMap({ $0 })
                .allSatisfy(isBoundedStatusField) else {
            return .unavailable(data.count > maximumOutputBytes ? .outputTooLarge : .malformedStatus)
        }

        return .available(
            VoxTypeStatusSnapshot(
                state: state,
                model: document.model,
                device: document.device,
                backend: document.backend
            )
        )
    }

    private static func isBoundedStatusField(_ field: String) -> Bool {
        !field.isEmpty
            && field.utf8.count <= maximumStatusFieldBytes
            && !field.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isSafeEngine(_ engine: String) -> Bool {
        guard !engine.isEmpty, engine.utf8.count <= 64 else { return false }
        return engine.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
        }
    }

    private static func parseVersion(_ output: String) -> VoxTypeVersion? {
        guard output.utf8.count <= maximumStatusFieldBytes else { return nil }
        for rawToken in output.split(whereSeparator: { $0.isWhitespace }).reversed() {
            let token = rawToken.hasPrefix("v") ? rawToken.dropFirst() : rawToken[...]
            let pieces = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
            guard core.count == 3,
                  core.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isNumber) }),
                  let major = Int(core[0]),
                  let minor = Int(core[1]),
                  let patch = Int(core[2]) else {
                continue
            }
            let prerelease = pieces.count == 2 ? String(pieces[1]) : nil
            guard prerelease?.utf8.count ?? 0 <= 64,
                  prerelease?.isEmpty != true,
                  prerelease?.utf8.allSatisfy({
                      ($0 >= 65 && $0 <= 90)
                          || ($0 >= 97 && $0 <= 122)
                          || ($0 >= 48 && $0 <= 57)
                          || $0 == 45
                          || $0 == 46
                  }) != false else {
                continue
            }
            return VoxTypeVersion(
                major: major,
                minor: minor,
                patch: patch,
                prerelease: prerelease
            )
        }
        return nil
    }

    private static func parseHotkeyConfiguration(
        _ output: String
    ) -> VoxTypeHotkeyConfiguration? {
        guard output.utf8.count <= maximumOutputBytes else { return nil }
        var isInHotkeySection = false
        var key: String?
        var modifiers: [String]?
        var mode: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if isInHotkeySection { break }
                isInHotkeySection = line == "[hotkey]"
                continue
            }
            guard isInHotkeySection,
                  let separator = line.firstIndex(of: "=") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)

            switch name {
            case "key":
                key = parseQuotedIdentifier(rawValue)
            case "modifiers":
                modifiers = parseIdentifierArray(rawValue)
            case "mode":
                mode = parseIdentifier(rawValue)
            default:
                continue
            }
        }

        guard let key, let modifiers, let mode else { return nil }
        return VoxTypeHotkeyConfiguration(key: key, modifiers: modifiers, mode: mode)
    }

    private static func parseQuotedIdentifier(_ value: String) -> String? {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return nil }
        return parseIdentifier(String(value.dropFirst().dropLast()))
    }

    private static func parseIdentifierArray(_ value: String) -> [String]? {
        guard value.first == "[", value.last == "]" else { return nil }
        let contents = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !contents.isEmpty else { return [] }
        let values = contents.split(separator: ",", omittingEmptySubsequences: false)
        let parsed = values.compactMap {
            parseQuotedIdentifier($0.trimmingCharacters(in: .whitespaces))
        }
        return parsed.count == values.count && parsed.count <= 8 ? parsed : nil
    }

    private static func parseIdentifier(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        guard value.utf8.allSatisfy({ byte in
            (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 45
                || byte == 95
        }) else { return nil }
        return value
    }

    private static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        let allowedKeys = [
            "HOME", "TMPDIR", "LANG", "LC_ALL",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR",
        ]
        return Dictionary(uniqueKeysWithValues: allowedKeys.compactMap { key in
            environment[key].map { (key, $0) }
        })
    }

    private static var defaultWorkingDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Brain", isDirectory: true)
            .appendingPathComponent("VoxTypeProcess", isDirectory: true)
    }
}


private struct VoxTypeStatusNDJSONDecoder {
    private let maximumLineBytes: Int
    private let decode: @Sendable (Data) -> VoxTypeStatus
    private var line = Data()
    private var discardingOversizedLine = false

    init(
        maximumLineBytes: Int,
        decode: @escaping @Sendable (Data) -> VoxTypeStatus
    ) {
        self.maximumLineBytes = maximumLineBytes
        self.decode = decode
        line.reserveCapacity(min(maximumLineBytes, 1_024))
    }

    mutating func append(_ data: Data) -> [VoxTypeStatus] {
        var statuses: [VoxTypeStatus] = []
        for byte in data {
            if discardingOversizedLine {
                if byte == 0x0A { discardingOversizedLine = false }
                continue
            }
            if byte == 0x0A {
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty { statuses.append(decode(line)) }
                line.removeAll(keepingCapacity: true)
                continue
            }
            guard line.count < maximumLineBytes else {
                line.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
                statuses.append(.unavailable(.outputTooLarge))
                continue
            }
            line.append(byte)
        }
        return statuses
    }

    mutating func finish() -> [VoxTypeStatus] {
        guard !discardingOversizedLine, !line.isEmpty else { return [] }
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { return [] }
        defer { line.removeAll(keepingCapacity: false) }
        return [decode(line)]
    }
}
