import Foundation

enum MeetingSystemAudioSlicer {
    static func samples(
        track: MeetingAudioTrack,
        startMilliseconds: Int64,
        endMilliseconds: Int64
    ) -> [Float]? {
        guard track.sampleRate == MeetingAudioWriter.sampleRate,
              track.channelCount == 1,
              endMilliseconds > startMilliseconds else { return nil }
        let start = Int(startMilliseconds) * track.sampleRate / 1_000
        let end = Int(endMilliseconds) * track.sampleRate / 1_000
        guard start >= 0, end > start else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: track.fileURL) else { return nil }
        defer { try? handle.close() }
        let byteStart = UInt64(start * MemoryLayout<Float>.size)
        let byteCount = (end - start) * MemoryLayout<Float>.size
        do {
            try handle.seek(toOffset: byteStart)
            guard let data = try handle.read(upToCount: byteCount),
                  data.count == byteCount else { return nil }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } catch {
            return nil
        }
    }
}
