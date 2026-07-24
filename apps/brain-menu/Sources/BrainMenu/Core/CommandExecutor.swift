import Darwin
import Foundation

struct CommandResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitStatus: Int32

    init(stdout: String, stderr: String = "", exitStatus: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }
}

protocol CommandExecutor: Sendable {
    func execute(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult
}

enum CommandExecutionError: Error, Equatable, LocalizedError, Sendable {
    case launchFailed(String)
    case timedOut(executable: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Could not launch the command: \(message)"
        case .timedOut(let executable, let seconds):
            return "\(executable) timed out after \(seconds.formatted()) seconds."
        }
    }
}

final class ProcessCommandExecutor: CommandExecutor {
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var didStop = false

        init(_ process: Process) {
            self.process = process
        }

        func stop() {
            lock.lock()
            guard !didStop else {
                lock.unlock()
                return
            }
            didStop = true
            lock.unlock()

            guard process.isRunning else { return }
            let identifier = process.processIdentifier
            process.terminate()
            if process.isRunning {
                Darwin.kill(identifier, SIGKILL)
            }
        }
    }

    private final class PipeBox: @unchecked Sendable {
        let pipe: Pipe

        init(_ pipe: Pipe) {
            self.pipe = pipe
        }
    }

    private enum Completion: Sendable {
        case exited(Int32)
        case timedOut
        case cancelled
    }

    func execute(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminationStatuses = AsyncStream<Int32> { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.yield(terminatedProcess.terminationStatus)
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw CommandExecutionError.launchFailed(error.localizedDescription)
        }

        let processBox = ProcessBox(process)
        let stdoutBox = PipeBox(stdoutPipe)
        let stderrBox = PipeBox(stderrPipe)
        let stdoutTask = Task.detached {
            stdoutBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderrBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }

        let completion = await withTaskGroup(of: Completion.self) { group in
            group.addTask {
                for await exitStatus in terminationStatuses {
                    return .exited(exitStatus)
                }
                return .cancelled
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(Int64(timeout * 1_000)))
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

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value

        switch completion {
        case .exited(let exitStatus):
            return CommandResult(
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                exitStatus: exitStatus
            )
        case .timedOut:
            throw CommandExecutionError.timedOut(
                executable: executable.path,
                seconds: timeout
            )
        case .cancelled:
            throw CancellationError()
        }
    }
}
