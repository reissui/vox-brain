import Foundation

struct SpeakerTalkTime: Codable, Equatable, Identifiable, Sendable {
    let speakerID: String
    let displayName: String
    let durationMilliseconds: Int64
    let percentage: Double
    let utteranceCount: Int
    let colorKey: String

    var id: String { speakerID }

    var accessibilityLabel: String {
        let seconds = Double(durationMilliseconds) / 1_000
        return "\(displayName), \(String(format: "%.1f", percentage)) percent, "
            + "\(String(format: "%.1f", seconds)) seconds, "
            + "\(utteranceCount) utterances"
    }
}

typealias TalkTimeChartDatum = SpeakerTalkTime

struct TalkTimeChart: Codable, Equatable, Sendable {
    let data: [SpeakerTalkTime]
    let totalAttributedSpeechMilliseconds: Int64

    var chartData: [SpeakerTalkTime] { data }
}

/// Calculates attributed speech from final, visible utterances. Each speaker's
/// own intervals are unioned independently, so overlapping chunks from one
/// speaker are not double counted while simultaneous speakers each retain
/// their full contribution.
struct TalkTimeCalculator: Sendable {
    private static let colorKeys = [
        "speaker-blue",
        "speaker-orange",
        "speaker-green",
        "speaker-purple",
        "speaker-pink",
        "speaker-teal",
        "speaker-gold",
        "speaker-indigo",
    ]

    func calculate(for editor: SpeakerEditor) -> TalkTimeChart {
        calculate(
            utterances: editor.utterances,
            assignments: editor.assignments,
            speakers: editor.speakers
        )
    }

    func calculate(
        utterances: [MeetingUtterance],
        assignments: [UUID: SpeakerAssignment] = [:],
        speakers: [String: MeetingSpeaker] = [:]
    ) -> TalkTimeChart {
        var intervalsBySpeaker: [String: [Interval]] = [:]
        var countsBySpeaker: [String: Int] = [:]

        for utterance in utterances where !utterance.suppressed {
            let speakerID = assignments[utterance.id]?.speakerID
                ?? defaultSpeakerID(for: utterance.source)
            countsBySpeaker[speakerID, default: 0] += 1
            guard utterance.endMilliseconds > utterance.startMilliseconds else { continue }
            intervalsBySpeaker[speakerID, default: []].append(Interval(
                start: utterance.startMilliseconds,
                end: utterance.endMilliseconds
            ))
        }

        let speakerIDs = Set(countsBySpeaker.keys).union(intervalsBySpeaker.keys)
        let durations = Dictionary(uniqueKeysWithValues: speakerIDs.map { speakerID in
            (speakerID, unionDuration(of: intervalsBySpeaker[speakerID, default: []]))
        })
        let total = durations.values.reduce(Int64(0), Self.saturatingAdd)

        var rows = speakerIDs.map { speakerID in
            DraftRow(
                speakerID: speakerID,
                displayName: speakers[speakerID]?.displayName
                    ?? SpeakerEditor.defaultDisplayName(for: speakerID),
                durationMilliseconds: durations[speakerID, default: 0],
                utteranceCount: countsBySpeaker[speakerID, default: 0],
                colorKey: Self.colorKey(for: speakerID)
            )
        }
        rows.sort {
            if $0.durationMilliseconds != $1.durationMilliseconds {
                return $0.durationMilliseconds > $1.durationMilliseconds
            }
            return $0.speakerID < $1.speakerID
        }

        var attributedPercentage = 0.0
        let lastSpeakingIndex = rows.lastIndex { $0.durationMilliseconds > 0 }
        let data = rows.enumerated().map { index, row in
            let percentage: Double
            if total == 0 {
                percentage = 0
            } else if index == lastSpeakingIndex {
                percentage = max(0, 100 - attributedPercentage)
            } else {
                percentage = Double(row.durationMilliseconds) / Double(total) * 100
                attributedPercentage += percentage
            }
            return SpeakerTalkTime(
                speakerID: row.speakerID,
                displayName: row.displayName,
                durationMilliseconds: row.durationMilliseconds,
                percentage: percentage,
                utteranceCount: row.utteranceCount,
                colorKey: row.colorKey
            )
        }

        return TalkTimeChart(
            data: data,
            totalAttributedSpeechMilliseconds: total
        )
    }

    func chartData(
        for utterances: [MeetingUtterance],
        assignments: [UUID: SpeakerAssignment] = [:],
        speakers: [String: MeetingSpeaker] = [:]
    ) -> [SpeakerTalkTime] {
        calculate(
            utterances: utterances,
            assignments: assignments,
            speakers: speakers
        ).data
    }

    static func colorKey(for speakerID: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in speakerID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return colorKeys[Int(hash % UInt64(colorKeys.count))]
    }

    private func unionDuration(of intervals: [Interval]) -> Int64 {
        let sorted = intervals.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        guard var current = sorted.first else { return 0 }

        var total: Int64 = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                total = Self.saturatingAdd(total, current.end - current.start)
                current = interval
            }
        }
        return Self.saturatingAdd(total, current.end - current.start)
    }

    private func defaultSpeakerID(for source: MeetingUtteranceSource) -> String {
        switch source {
        case .microphone:
            SpeakerEditor.youSpeakerID
        case .system:
            SpeakerEditor.remoteSpeakerID
        }
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private struct Interval {
        let start: Int64
        var end: Int64
    }

    private struct DraftRow {
        let speakerID: String
        let displayName: String
        let durationMilliseconds: Int64
        let utteranceCount: Int
        let colorKey: String
    }
}
