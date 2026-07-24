import Darwin
import Foundation

struct VoxTypeLogCursor: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let offset: Int64
    let anchor: Data?

    init(device: UInt64, inode: UInt64, offset: Int64, anchor: Data? = nil) {
        self.device = device
        self.inode = inode
        self.offset = offset
        self.anchor = anchor
    }
}

struct VoxTypeLogEntryIdentity: Hashable {
    let completedAtMilliseconds: Int64
    let text: String

    init(completedAt: Date, text: String) {
        completedAtMilliseconds = Int64(
            (completedAt.timeIntervalSince1970 * 1_000).rounded()
        )
        self.text = text
    }
}

enum VoxTypeLogReader {
    struct Entry: Equatable {
        let completedAt: Date
        let text: String
    }

    struct Batch: Equatable {
        let cursor: VoxTypeLogCursor
        let entries: [Entry]
    }

    private enum Event {
        case transcribed(Entry)
        case outputSucceeded
        case outputAborted
        case unrelated
    }

    static func read(
        from url: URL,
        after previousCursor: VoxTypeLogCursor?,
        maximumBytes: Int
    ) throws -> Batch? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw DictationHistoryError.unsafeVoxTypeLog }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_size >= 0 else {
            throw DictationHistoryError.unsafeVoxTypeLog
        }

        let device = UInt64(information.st_dev)
        let inode = UInt64(information.st_ino)
        let fileSize = Int64(information.st_size)
        var startOffset: Int64 = 0
        if let previousCursor,
           previousCursor.device == device,
           previousCursor.inode == inode,
           previousCursor.offset >= 0,
           previousCursor.offset <= fileSize,
           try anchor(descriptor: descriptor, endingAt: previousCursor.offset)
                == previousCursor.anchor {
            startOffset = previousCursor.offset
        }

        var clippedFirstLine = false
        if fileSize - startOffset > Int64(maximumBytes) {
            startOffset = fileSize - Int64(maximumBytes)
            clippedFirstLine = startOffset > 0
        }
        guard startOffset < fileSize else {
            return Batch(
                cursor: VoxTypeLogCursor(
                    device: device,
                    inode: inode,
                    offset: fileSize,
                    anchor: try anchor(descriptor: descriptor, endingAt: fileSize)
                ),
                entries: []
            )
        }

        let data = try read(
            descriptor: descriptor,
            count: Int(fileSize - startOffset),
            offset: startOffset
        )
        var scanIndex = 0
        if clippedFirstLine {
            guard let newline = data.firstIndex(of: 0x0A) else {
                return Batch(
                    cursor: VoxTypeLogCursor(
                        device: device,
                        inode: inode,
                        offset: fileSize,
                        anchor: try anchor(descriptor: descriptor, endingAt: fileSize)
                    ),
                    entries: []
                )
            }
            scanIndex = newline + 1
        }

        var lastCompleteOffset = startOffset + Int64(scanIndex)
        var pending: (entry: Entry, offset: Int64)?
        var entries: [Entry] = []

        while scanIndex < data.count,
              let newline = data[scanIndex...].firstIndex(of: 0x0A) {
            let lineStart = scanIndex
            var lineEnd = newline
            if lineEnd > lineStart, data[lineEnd - 1] == 0x0D {
                lineEnd -= 1
            }
            let line = String(decoding: data[lineStart..<lineEnd], as: UTF8.self)
            let absoluteLineStart = startOffset + Int64(lineStart)
            lastCompleteOffset = startOffset + Int64(newline + 1)

            switch try event(in: line) {
            case let .transcribed(entry):
                pending = (entry, absoluteLineStart)
            case .outputSucceeded:
                if let completed = pending {
                    entries.append(completed.entry)
                    pending = nil
                }
            case .outputAborted:
                pending = nil
            case .unrelated:
                break
            }
            scanIndex = newline + 1
        }

        // A log write may be observed between the final transcript line and
        // VoxType's output-success line. Re-read from the transcript on the
        // next poll so Brain never records text that VoxType did not deliver.
        let consumedOffset = pending?.offset ?? lastCompleteOffset
        return Batch(
            cursor: VoxTypeLogCursor(
                device: device,
                inode: inode,
                offset: consumedOffset,
                anchor: try anchor(descriptor: descriptor, endingAt: consumedOffset)
            ),
            entries: entries
        )
    }

    private static func event(in line: String) throws -> Event {
        if let marker = line.range(of: "Transcribed: ") {
            let prefix = String(line[..<marker.lowerBound])
            guard let completedAt = timestamp(in: prefix),
                  let text = decodedJSONString(in: String(line[marker.upperBound...])),
                  !text.isEmpty else {
                throw DictationHistoryError.invalidVoxTypeLog
            }
            return .transcribed(Entry(completedAt: completedAt, text: text))
        }
        if [
            "Text typed via CGEvent (",
            "Text typed via osascript (",
            "Text pasted via clipboard + ",
            "Text output via ",
        ].contains(where: line.contains) {
            return .outputSucceeded
        }
        if [
            "output failed",
            "Output failed",
            "typing failed",
            "Typing failed",
            "paste failed",
            "Paste failed",
            "cancelled",
            "Canceled",
        ].contains(where: line.contains) {
            return .outputAborted
        }
        return .unrelated
    }

    private static func timestamp(in text: String) -> Date? {
        guard let range = text.range(
            of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let value = String(text[range])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func decodedJSONString(in suffix: String) -> String? {
        let bytes = Array(suffix.utf8)
        guard let start = bytes.firstIndex(of: 0x22) else { return nil }
        var escaped = false
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let encoded = Data(bytes[start...index])
                return try? JSONDecoder().decode(String.self, from: encoded)
            }
            index += 1
        }
        return nil
    }

    private static func read(descriptor: Int32, count: Int, offset: Int64) throws -> Data {
        var result = Data(count: count)
        var bytesRead = 0
        try result.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while bytesRead < count {
                let amount = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: bytesRead),
                    count - bytesRead,
                    off_t(offset + Int64(bytesRead))
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else {
                    throw DictationHistoryError.voxTypeLogReadFailed
                }
                bytesRead += amount
            }
        }
        return result
    }

    private static func anchor(descriptor: Int32, endingAt offset: Int64) throws -> Data {
        let count = Int(min(offset, 64))
        guard count > 0 else { return Data() }
        return try read(
            descriptor: descriptor,
            count: count,
            offset: offset - Int64(count)
        )
    }
}
