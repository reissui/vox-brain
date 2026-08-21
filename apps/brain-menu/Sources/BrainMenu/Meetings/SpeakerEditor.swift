import Foundation

enum SpeakerAssignmentProvenance: String, Codable, CaseIterable, Sendable {
    case sourceDefault
    case aiSuggestion
    case aiAccepted
    case manual

    static let automatic = Self.sourceDefault
    static let ai = Self.aiSuggestion
}

struct SpeakerAssignment: Codable, Equatable, Sendable {
    var speakerID: String
    var provenance: SpeakerAssignmentProvenance

    init(speakerID: String, provenance: SpeakerAssignmentProvenance) {
        self.speakerID = speakerID
        self.provenance = provenance
    }
}

struct MeetingSpeaker: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// The durable portion of speaker editing. Assignments are keyed by stable
/// utterance IDs so a fresh transcription pass can reuse the user's choices
/// without making the transcript text itself mutable speaker metadata.
struct SpeakerEditingState: Codable, Equatable, Sendable {
    var assignments: [UUID: SpeakerAssignment]
    var speakers: [String: MeetingSpeaker]
    var mergedSpeakerIDs: [String: String]

    init(
        assignments: [UUID: SpeakerAssignment] = [:],
        speakers: [String: MeetingSpeaker] = [:],
        mergedSpeakerIDs: [String: String] = [:]
    ) {
        self.assignments = assignments
        self.speakers = speakers
        self.mergedSpeakerIDs = mergedSpeakerIDs
    }
}

/// Applies reversible speaker metadata edits without changing an utterance's
/// stable ID, source, text, or timestamps.
struct SpeakerEditor: Sendable {
    static let youSpeakerID = "you"
    static let remoteSpeakerID = "remote"

    private(set) var utterances: [MeetingUtterance]
    private(set) var state: SpeakerEditingState
    private var undoStack: [Snapshot] = []

    var assignments: [UUID: SpeakerAssignment] {
        state.assignments
    }

    var speakers: [String: MeetingSpeaker] {
        state.speakers
    }

    init(
        utterances: [MeetingUtterance],
        state: SpeakerEditingState = SpeakerEditingState()
    ) {
        self.utterances = utterances
        self.state = state
        reconcileAssignmentsWithUtterances()
    }

    init(
        utterances: [MeetingUtterance],
        savedAssignments: [UUID: SpeakerAssignment],
        speakers: [String: MeetingSpeaker] = [:]
    ) {
        self.init(
            utterances: utterances,
            state: SpeakerEditingState(
                assignments: savedAssignments,
                speakers: speakers
            )
        )
    }

    init(
        utterances: [MeetingUtterance],
        savedAssignments: [UUID: SpeakerAssignment],
        speakerList: [MeetingSpeaker]
    ) {
        self.init(
            utterances: utterances,
            savedAssignments: savedAssignments,
            speakers: Dictionary(uniqueKeysWithValues: speakerList.map { ($0.id, $0) })
        )
    }

    func assignment(for utteranceID: UUID) -> SpeakerAssignment? {
        state.assignments[utteranceID]
    }

    func speakerID(for utteranceID: UUID) -> String? {
        state.assignments[utteranceID]?.speakerID
    }

    func speaker(for speakerID: String) -> MeetingSpeaker? {
        state.speakers[canonicalSpeakerID(for: speakerID)]
    }

    func displayName(for speakerID: String) -> String? {
        speaker(for: speakerID)?.displayName
    }

    @discardableResult
    mutating func rename(speakerID: String, to displayName: String) -> Bool {
        renameSpeaker(speakerID, to: displayName)
    }

    @discardableResult
    mutating func renameSpeaker(_ speakerID: String, to displayName: String) -> Bool {
        let canonicalID = canonicalSpeakerID(for: speakerID)
        guard !displayName.isEmpty else { return false }
        let current = state.speakers[canonicalID]
            ?? MeetingSpeaker(id: canonicalID, displayName: Self.defaultDisplayName(for: canonicalID))
        guard current.displayName != displayName else { return false }

        recordUndoSnapshot()
        state.speakers[canonicalID] = MeetingSpeaker(
            id: canonicalID,
            displayName: displayName
        )
        synchronizeUtteranceSpeakerMetadata()
        return true
    }

    @discardableResult
    mutating func merge(speakerIDs: [String], into canonicalSpeakerID: String) -> Bool {
        mergeSpeakers(speakerIDs, into: canonicalSpeakerID)
    }

    @discardableResult
    mutating func mergeSpeakers(
        _ speakerIDs: [String],
        into canonicalSpeakerID: String
    ) -> Bool {
        let canonicalID = self.canonicalSpeakerID(for: canonicalSpeakerID)
        let sourceIDs = Set(speakerIDs.map { self.canonicalSpeakerID(for: $0) })
            .subtracting([canonicalID])
        guard !sourceIDs.isEmpty else { return false }

        let assignmentIDsToMerge = state.assignments.compactMap { utteranceID, assignment in
            sourceIDs.contains(self.canonicalSpeakerID(for: assignment.speakerID))
                ? utteranceID
                : nil
        }
        let changesAssignment = !assignmentIDsToMerge.isEmpty
        let changesAlias = sourceIDs.contains { state.mergedSpeakerIDs[$0] != canonicalID }
        guard changesAssignment || changesAlias else { return false }

        recordUndoSnapshot()
        ensureSpeaker(canonicalID)

        // Redirect direct and transitive aliases. This also makes the merge
        // apply to newly reprocessed utterances that return with a source ID.
        for (source, destination) in Array(state.mergedSpeakerIDs)
        where sourceIDs.contains(self.canonicalSpeakerID(for: destination)) {
            state.mergedSpeakerIDs[source] = canonicalID
        }
        for sourceID in sourceIDs {
            state.mergedSpeakerIDs[sourceID] = canonicalID
            state.speakers.removeValue(forKey: sourceID)
        }

        for utteranceID in assignmentIDsToMerge {
            state.assignments[utteranceID] = SpeakerAssignment(
                speakerID: canonicalID,
                provenance: .manual
            )
        }
        synchronizeUtteranceSpeakerMetadata()
        return true
    }

    @discardableResult
    mutating func reassign(utteranceIDs: Set<UUID>, to speakerID: String) -> Bool {
        reassignUtterances(utteranceIDs, to: speakerID)
    }

    @discardableResult
    mutating func reassignUtterances(
        _ utteranceIDs: Set<UUID>,
        to speakerID: String
    ) -> Bool {
        let knownIDs = Set(utterances.map(\.id))
        let selectedIDs = utteranceIDs.intersection(knownIDs)
        let canonicalID = canonicalSpeakerID(for: speakerID)
        let changedIDs = selectedIDs.filter {
            state.assignments[$0] != SpeakerAssignment(
                speakerID: canonicalID,
                provenance: .manual
            )
        }
        guard !changedIDs.isEmpty else { return false }

        recordUndoSnapshot()
        ensureSpeaker(canonicalID)
        for utteranceID in changedIDs {
            state.assignments[utteranceID] = SpeakerAssignment(
                speakerID: canonicalID,
                provenance: .manual
            )
        }
        synchronizeUtteranceSpeakerMetadata()
        return true
    }

    /// Removes selected utterances from the editable transcript. The immutable
    /// raw artifact is unchanged; suppressions flow into processed output.
    @discardableResult
    mutating func suppress(utteranceIDs: Set<UUID>) -> Bool {
        let knownIDs = Set(utterances.map(\.id))
        let selectedIDs = utteranceIDs.intersection(knownIDs)
        guard !selectedIDs.isEmpty else { return false }
        var changed = false
        for index in utterances.indices {
            guard selectedIDs.contains(utterances[index].id),
                  !utterances[index].suppressed else { continue }
            utterances[index].suppressed = true
            changed = true
        }
        return changed
    }

    /// Creates a deterministic ID from the original speaker and selected
    /// stable utterance IDs. The result therefore survives persistence and a
    /// later transcript-processing pass without relying on array position.
    @discardableResult
    mutating func split(
        speakerID: String,
        utteranceIDs: Set<UUID>,
        displayName: String? = nil
    ) -> String {
        splitSpeaker(
            speakerID,
            utteranceIDs: utteranceIDs,
            displayName: displayName
        )
    }

    @discardableResult
    mutating func splitSpeaker(
        _ speakerID: String,
        utteranceIDs: Set<UUID>,
        displayName: String? = nil
    ) -> String {
        let canonicalSourceID = canonicalSpeakerID(for: speakerID)
        let selectedIDs = utteranceIDs.filter {
            state.assignments[$0]?.speakerID == canonicalSourceID
        }
        guard !selectedIDs.isEmpty else { return canonicalSourceID }

        let newSpeakerID = stableSplitSpeakerID(
            sourceSpeakerID: canonicalSourceID,
            utteranceIDs: selectedIDs
        )
        recordUndoSnapshot()
        state.speakers[newSpeakerID] = MeetingSpeaker(
            id: newSpeakerID,
            displayName: displayName ?? Self.defaultDisplayName(for: newSpeakerID)
        )
        for utteranceID in selectedIDs {
            state.assignments[utteranceID] = SpeakerAssignment(
                speakerID: newSpeakerID,
                provenance: .manual
            )
        }
        synchronizeUtteranceSpeakerMetadata()
        return newSpeakerID
    }

    /// AI output is advisory. Every suggestion is labelled as such, and a
    /// manual assignment is intentionally skipped even when the suggestion
    /// names a merged speaker alias.
    mutating func applyAISuggestions(_ suggestions: [UUID: String]) {
        let knownIDs = Set(utterances.map(\.id))
        for (utteranceID, suggestedSpeakerID) in suggestions
        where knownIDs.contains(utteranceID)
            && state.assignments[utteranceID]?.provenance != .manual
            && state.assignments[utteranceID]?.provenance != .aiAccepted {
            let canonicalID = canonicalSpeakerID(for: suggestedSpeakerID)
            ensureSpeaker(canonicalID)
            state.assignments[utteranceID] = SpeakerAssignment(
                speakerID: canonicalID,
                provenance: canonicalID == suggestedSpeakerID ? .aiSuggestion : .manual
            )
        }
        synchronizeUtteranceSpeakerMetadata()
    }

    /// Applies one explicit user acceptance. Unlike advisory suggestions, the
    /// resulting assignment survives later suggestions and carries durable
    /// `aiAccepted` provenance. Manual assignments always win.
    @discardableResult
    mutating func acceptAISuggestion(
        utteranceID: UUID,
        speakerID: String,
        displayName: String
    ) -> Bool {
        guard utterances.contains(where: { $0.id == utteranceID }),
              state.assignments[utteranceID]?.provenance != .manual,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let canonicalID = canonicalSpeakerID(for: speakerID)
        let accepted = SpeakerAssignment(speakerID: canonicalID, provenance: .aiAccepted)
        guard state.assignments[utteranceID] != accepted
                || state.speakers[canonicalID]?.displayName != displayName else {
            return false
        }

        recordUndoSnapshot()
        state.speakers[canonicalID] = MeetingSpeaker(id: canonicalID, displayName: displayName)
        state.assignments[utteranceID] = accepted
        synchronizeUtteranceSpeakerMetadata()
        return true
    }

    mutating func applyAISuggestions(_ suggestions: [UUID: SpeakerAssignment]) {
        applyAISuggestions(suggestions.mapValues(\.speakerID))
    }

    /// Replaces the transcript data while retaining every saved assignment
    /// whose stable utterance ID is still present. New utterances receive only
    /// their source-aware default (or a previously merged source alias).
    mutating func reprocessFinalUtterances(_ reprocessedUtterances: [MeetingUtterance]) {
        utterances = reprocessedUtterances
        reconcileAssignmentsWithUtterances()
        undoStack.removeAll()
    }

    mutating func replaceFinalUtterances(_ reprocessedUtterances: [MeetingUtterance]) {
        reprocessFinalUtterances(reprocessedUtterances)
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let snapshot = undoStack.popLast() else { return false }
        utterances = snapshot.utterances
        state = snapshot.state
        return true
    }

    private mutating func reconcileAssignmentsWithUtterances() {
        for utterance in utterances {
            if let savedAssignment = state.assignments[utterance.id] {
                let canonicalID = canonicalSpeakerID(for: savedAssignment.speakerID)
                let provenance: SpeakerAssignmentProvenance =
                    canonicalID == savedAssignment.speakerID
                    ? savedAssignment.provenance
                    : .manual
                state.assignments[utterance.id] = SpeakerAssignment(
                    speakerID: canonicalID,
                    provenance: provenance
                )
                ensureSpeaker(canonicalID, fallbackName: utterance.humanName)
            } else {
                let sourceID = MeetingSpeakerIdentity.resolved(
                    source: utterance.source,
                    baseSpeakerID: utterance.baseSpeakerID,
                    assignment: nil,
                    speakers: state.speakers
                ).id
                let canonicalID = canonicalSpeakerID(for: sourceID)
                state.assignments[utterance.id] = SpeakerAssignment(
                    speakerID: canonicalID,
                    provenance: canonicalID == sourceID ? .sourceDefault : .manual
                )
                ensureSpeaker(canonicalID)
            }
        }
        synchronizeUtteranceSpeakerMetadata()
    }

    private mutating func synchronizeUtteranceSpeakerMetadata() {
        for index in utterances.indices {
            guard let assignment = state.assignments[utterances[index].id] else { continue }
            let canonicalID = canonicalSpeakerID(for: assignment.speakerID)
            ensureSpeaker(canonicalID, fallbackName: utterances[index].humanName)
            utterances[index].baseSpeakerID = canonicalID
            utterances[index].humanName = state.speakers[canonicalID]?.displayName
        }
    }

    private mutating func ensureSpeaker(_ speakerID: String, fallbackName: String? = nil) {
        guard state.speakers[speakerID] == nil else { return }
        state.speakers[speakerID] = MeetingSpeaker(
            id: speakerID,
            displayName: fallbackName ?? Self.defaultDisplayName(for: speakerID)
        )
    }

    private func canonicalSpeakerID(for speakerID: String) -> String {
        var current = speakerID
        var visited: Set<String> = []
        while let next = state.mergedSpeakerIDs[current], !visited.contains(current) {
            visited.insert(current)
            current = next
        }
        return current
    }

    private mutating func recordUndoSnapshot() {
        undoStack.append(Snapshot(utterances: utterances, state: state))
    }

    private func stableSplitSpeakerID(
        sourceSpeakerID: String,
        utteranceIDs: Set<UUID>
    ) -> String {
        let seed = ([sourceSpeakerID] + utteranceIDs.map(\.uuidString).sorted())
            .joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let base = "speaker-" + String(hash, radix: 16)
        guard state.speakers[base] != nil else { return base }

        var suffix = 2
        while state.speakers["\(base)-\(suffix)"] != nil {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private static func defaultSpeakerID(for source: MeetingUtteranceSource) -> String {
        switch source {
        case .microphone:
            youSpeakerID
        case .system:
            remoteSpeakerID
        }
    }

    static func defaultDisplayName(for speakerID: String) -> String {
        switch speakerID {
        case youSpeakerID:
            return "You"
        case remoteSpeakerID:
            return "Remote"
        default:
            if MeetingSpeakerIdentity.isClusteredID(speakerID),
               let number = Int(speakerID.dropFirst("remote-".count)) {
                return "Speaker \(number)"
            }
            return "Speaker"
        }
    }

    private struct Snapshot: Sendable {
        let utterances: [MeetingUtterance]
        let state: SpeakerEditingState
    }
}

typealias Speaker = MeetingSpeaker
typealias SpeakerProvenance = SpeakerAssignmentProvenance
