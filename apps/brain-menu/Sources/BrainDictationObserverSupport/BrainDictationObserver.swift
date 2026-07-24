import Darwin
import Foundation

public enum BrainDictationObserver {
    public static let maximumTranscriptBytes = 1_048_576

    private static let frameMagic = Data("BRDCT001".utf8)
    private static let genericError = Data("Brain dictation history capture unavailable.\n".utf8)

    /// Synchronous compatibility entry point used by direct library callers
    /// and tests. Production uses `runPastePath` so persistence happens later.
    public static func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError,
        directoryURL: URL? = nil
    ) {
        guard let captured = forwardTranscript(
            input: input,
            output: output,
            errorOutput: errorOutput
        ) else { return }

        persist(captured, errorOutput: errorOutput, directoryURL: directoryURL)
    }

    /// Forwards VoxType's bytes immediately and returns a private copy for the
    /// persistence worker. This function performs no file-system durability work.
    public static func forwardTranscript(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError
    ) -> Data? {
        readTranscript(input: input, output: output, errorOutput: errorOutput)
    }

    /// Production paste path: publish stdout/EOF first, then hand history work
    /// to a separate process. VoxType never waits for the file lock or fsync.
    public static func runPastePath(
        executableURL: URL,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError
    ) {
        let transcript = forwardTranscript(
            input: input,
            output: output,
            errorOutput: errorOutput
        )
        try? output.close()
        guard let transcript else { return }
        do {
            try launchPersistenceWorker(
                executableURL: executableURL,
                transcript: transcript
            )
        } catch {
            reportFailure(to: errorOutput)
        }
    }

    /// Starts a separate worker and hands it the transcript over stdin without
    /// waiting for history persistence to finish.
    public static func launchPersistenceWorker(
        executableURL: URL,
        transcript: Data,
        directoryURL: URL? = nil
    ) throws {
        guard !transcript.isEmpty, transcript.count <= maximumTranscriptBytes else {
            throw ObserverError.io
        }

        let process = Process()
        let inputPipe = Pipe()
        process.executableURL = executableURL.standardizedFileURL
        process.arguments = ["--persist-history"] + (directoryURL.map { [$0.path] } ?? [])
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try inputPipe.fileHandleForReading.close()
        try inputPipe.fileHandleForWriting.write(contentsOf: transcript)
        try inputPipe.fileHandleForWriting.close()
    }

    /// Entry point for the detached worker process.
    public static func runPersistenceWorker(
        input: FileHandle = .standardInput,
        errorOutput: FileHandle = .standardError,
        directoryURL: URL? = nil
    ) {
        guard let captured = readTranscript(
            input: input,
            output: nil,
            errorOutput: errorOutput
        ) else { return }
        persist(captured, errorOutput: errorOutput, directoryURL: directoryURL)
    }

    private static func readTranscript(
        input: FileHandle,
        output: FileHandle?,
        errorOutput: FileHandle
    ) -> Data? {
        var captured = Data()
        var canCapture = true

        do {
            while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                try output?.write(contentsOf: chunk)
                if canCapture {
                    if captured.count + chunk.count <= maximumTranscriptBytes {
                        captured.append(chunk)
                    } else {
                        canCapture = false
                        captured.removeAll(keepingCapacity: false)
                    }
                }
            }
        } catch {
            reportFailure(to: errorOutput)
            return nil
        }

        guard canCapture, !captured.isEmpty,
              String(data: captured, encoding: .utf8) != nil else {
            if !canCapture { reportFailure(to: errorOutput) }
            return nil
        }
        return captured
    }

    private static func persist(
        _ captured: Data,
        errorOutput: FileHandle,
        directoryURL: URL?
    ) {
        do {
            try append(captured, directoryURL: directoryURL ?? defaultDirectoryURL())
        } catch {
            reportFailure(to: errorOutput)
        }
    }

    private static func append(_ transcript: Data, directoryURL: URL) throws {
        try preparePrivateDirectory(directoryURL)
        let lockURL = directoryURL.appendingPathComponent("handoff.lock", isDirectory: false)
        let handoffURL = directoryURL.appendingPathComponent("handoff.frames", isDirectory: false)

        let lockDescriptor = openPrivateFile(lockURL, flags: O_RDWR | O_CREAT)
        guard lockDescriptor >= 0 else { throw ObserverError.io }
        defer { close(lockDescriptor) }
        try validatePrivateRegularFile(lockDescriptor)
        guard flock(lockDescriptor, LOCK_EX) == 0 else { throw ObserverError.io }
        defer { flock(lockDescriptor, LOCK_UN) }

        let handoffDescriptor = openPrivateFile(
            handoffURL,
            flags: O_WRONLY | O_CREAT | O_APPEND
        )
        guard handoffDescriptor >= 0 else { throw ObserverError.io }
        defer { close(handoffDescriptor) }
        try validatePrivateRegularFile(handoffDescriptor)

        let identifier = Data(UUID().uuidString.utf8)
        let milliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let bodyLength = 36 + MemoryLayout<Int64>.size + MemoryLayout<UInt32>.size
            + transcript.count
        guard bodyLength <= Int(UInt32.max) else { throw ObserverError.io }

        var frame = Data(capacity: frameMagic.count + 4 + bodyLength)
        frame.append(frameMagic)
        frame.appendBigEndian(UInt32(bodyLength))
        frame.append(identifier)
        frame.appendBigEndian(UInt64(bitPattern: milliseconds))
        frame.appendBigEndian(UInt32(transcript.count))
        frame.append(transcript)
        try writeAll(frame, to: handoffDescriptor)
        guard fsync(handoffDescriptor) == 0 else { throw ObserverError.io }
    }

    private static func defaultDirectoryURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw ObserverError.io }
        return applicationSupport
            .appendingPathComponent("Brain", isDirectory: true)
            .appendingPathComponent("Dictation", isDirectory: true)
    }

    private static func preparePrivateDirectory(_ directoryURL: URL) throws {
        let parent = directoryURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try createOrValidatePrivateDirectory(parent)
        }
        try createOrValidatePrivateDirectory(directoryURL)
    }

    private static func createOrValidatePrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw ObserverError.io }
        var information = stat()
        guard lstat(url.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid(),
              chmod(url.path, 0o700) == 0 else {
            throw ObserverError.io
        }
    }

    private static func openPrivateFile(_ url: URL, flags: Int32) -> Int32 {
        open(url.path, flags | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    }

    private static func validatePrivateRegularFile(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              fchmod(descriptor, 0o600) == 0 else {
            throw ObserverError.io
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ObserverError.io }
                offset += result
            }
        }
    }

    private static func reportFailure(to errorOutput: FileHandle) {
        try? errorOutput.write(contentsOf: genericError)
    }
}

private enum ObserverError: Error {
    case io
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
