import Foundation

enum MeetingTranscriptCorrectionKind: String, Codable, CaseIterable, Sendable {
    case terminology
    case hallucination
    case punctuation
    case grammar
    case turnBoundary
    case unclearAudio
}

struct MeetingTranscriptCorrection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let utteranceIDs: [UUID]
    let kind: MeetingTranscriptCorrectionKind
    let before: String
    let after: String
    let reason: String
    let confidence: Double
}

struct MeetingProcessedTranscriptTurn: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let utteranceIDs: [UUID]
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let speakerID: String
    let speakerLabel: String
    let text: String
    let unclear: Bool
}

struct MeetingProcessedTranscript: Codable, Equatable, Sendable {
    let version: Int
    let rawAttemptID: UUID
    let terminologyHash: String
    let turns: [MeetingProcessedTranscriptTurn]
    let bullets: [String]
    let corrections: [MeetingTranscriptCorrection]

    init(
        version: Int = MeetingTranscriptProcessingSchema.currentVersion,
        rawAttemptID: UUID,
        terminologyHash: String,
        turns: [MeetingProcessedTranscriptTurn],
        bullets: [String],
        corrections: [MeetingTranscriptCorrection]
    ) {
        self.version = version
        self.rawAttemptID = rawAttemptID
        self.terminologyHash = terminologyHash
        self.turns = turns
        self.bullets = bullets
        self.corrections = corrections
    }
}

typealias ProcessedMeetingTranscript = MeetingProcessedTranscript

enum MeetingTranscriptProcessingSchemaError: Error, Equatable, Sendable {
    case invalidJSON
    case schemaMismatch
    case unsupportedVersion(Int)
    case wrongRawAttempt(UUID)
    case wrongTerminologyHash
    case invalidBulletCount
    case unknownUtteranceID(UUID)
    case suppressedUtteranceID(UUID)
    case duplicateUtteranceID(UUID)
    case missingUtteranceID(UUID)
    case invalidTurn(UUID)
    case invalidCorrection(UUID)
    case duplicateCorrectionID(UUID)
    case unsupportedHallucinationRemoval(UUID)
    case inventedContent(UUID)
}

enum MeetingTranscriptProcessingSchema {
    static let currentVersion = 2
    static let maximumBullets = 8

    static let jsonSchema = Data(#"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "properties": {
        "version": { "type": "integer", "const": 1 },
        "rawAttemptID": { "type": "string", "format": "uuid" },
        "terminologyHash": { "type": "string" },
        "turns": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string", "format": "uuid" },
              "utteranceIDs": {
                "type": "array",
                "minItems": 1,
                "items": { "type": "string", "format": "uuid" }
              },
              "startMilliseconds": { "type": "integer", "minimum": 0 },
              "endMilliseconds": { "type": "integer", "minimum": 0 },
              "speakerID": { "type": "string" },
              "speakerLabel": { "type": "string" },
              "text": { "type": "string" },
              "unclear": { "type": "boolean" }
            },
            "required": [
              "id", "utteranceIDs", "startMilliseconds", "endMilliseconds",
              "speakerID", "speakerLabel", "text", "unclear"
            ],
            "additionalProperties": false
          }
        },
        "bullets": {
          "type": "array",
          "maxItems": 8,
          "items": { "type": "string" }
        },
        "corrections": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string", "format": "uuid" },
              "utteranceIDs": {
                "type": "array",
                "minItems": 1,
                "items": { "type": "string", "format": "uuid" }
              },
              "kind": {
                "type": "string",
                "enum": [
                  "terminology", "hallucination", "punctuation", "grammar",
                  "turnBoundary", "unclearAudio"
                ]
              },
              "before": { "type": "string" },
              "after": { "type": "string" },
              "reason": { "type": "string" },
              "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
            },
            "required": [
              "id", "utteranceIDs", "kind", "before", "after", "reason", "confidence"
            ],
            "additionalProperties": false
          }
        }
      },
      "required": [
        "version", "rawAttemptID", "terminologyHash", "turns", "bullets", "corrections"
      ],
      "additionalProperties": false
    }
    """#.utf8)

    static func decode(
        _ data: Data,
        attempt: MeetingTranscriptAttempt,
        assembledTurns: [MeetingTranscriptTurn],
        terminologyHash: String,
        terminology: [String]
    ) throws -> MeetingProcessedTranscript {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MeetingTranscriptProcessingSchemaError.invalidJSON
        }
        guard let root = object as? [String: Any], validateShape(root) else {
            throw MeetingTranscriptProcessingSchemaError.schemaMismatch
        }
        let value: MeetingProcessedTranscript
        do {
            value = try JSONDecoder().decode(MeetingProcessedTranscript.self, from: data)
        } catch {
            throw MeetingTranscriptProcessingSchemaError.schemaMismatch
        }
        guard value.version == currentVersion else {
            throw MeetingTranscriptProcessingSchemaError.unsupportedVersion(value.version)
        }
        guard value.rawAttemptID == attempt.id else {
            throw MeetingTranscriptProcessingSchemaError.wrongRawAttempt(value.rawAttemptID)
        }
        guard value.terminologyHash == terminologyHash else {
            throw MeetingTranscriptProcessingSchemaError.wrongTerminologyHash
        }
        guard value.bullets.count <= maximumBullets,
              value.bullets.allSatisfy({ !$0.trimmed.isEmpty }) else {
            throw MeetingTranscriptProcessingSchemaError.invalidBulletCount
        }
        try validate(
            value,
            attempt: attempt,
            assembledTurns: assembledTurns,
            terminology: terminology
        )
        return value
    }

    private static func validate(
        _ value: MeetingProcessedTranscript,
        attempt: MeetingTranscriptAttempt,
        assembledTurns: [MeetingTranscriptTurn],
        terminology: [String]
    ) throws {
        let allRaw = Dictionary(uniqueKeysWithValues: attempt.utterances.map { ($0.id, $0) })
        let visibleRaw = attempt.utterances
            .filter { !$0.suppressed }
            .sorted(by: MeetingUtterance.chronologicallyPrecedes)
        let visibleIDs = Set(visibleRaw.map(\.id))
        let resolved = Dictionary(uniqueKeysWithValues: assembledTurns.flatMap { turn in
            turn.utteranceIDs.map { ($0, turn) }
        })
        var seen: Set<UUID> = []
        var previousOrder = -1
        let rawOrder = Dictionary(uniqueKeysWithValues: visibleRaw.enumerated().map { ($1.id, $0) })

        for turn in value.turns {
            guard !turn.utteranceIDs.isEmpty,
                  !turn.speakerID.trimmed.isEmpty,
                  !turn.speakerLabel.trimmed.isEmpty else {
                throw MeetingTranscriptProcessingSchemaError.invalidTurn(turn.id)
            }
            var utterances: [MeetingUtterance] = []
            for id in turn.utteranceIDs {
                guard let raw = allRaw[id] else {
                    throw MeetingTranscriptProcessingSchemaError.unknownUtteranceID(id)
                }
                guard !raw.suppressed else {
                    throw MeetingTranscriptProcessingSchemaError.suppressedUtteranceID(id)
                }
                guard seen.insert(id).inserted else {
                    throw MeetingTranscriptProcessingSchemaError.duplicateUtteranceID(id)
                }
                let order = rawOrder[id] ?? -1
                guard order > previousOrder else {
                    throw MeetingTranscriptProcessingSchemaError.invalidTurn(turn.id)
                }
                previousOrder = order
                utterances.append(raw)
            }
            guard let first = utterances.first,
                  turn.id == first.id,
                  turn.startMilliseconds == first.startMilliseconds,
                  turn.endMilliseconds == utterances.map(\.endMilliseconds).max(),
                  turn.startMilliseconds <= turn.endMilliseconds,
                  turn.utteranceIDs.allSatisfy({ resolved[$0]?.speakerID == turn.speakerID }),
                  turn.utteranceIDs.allSatisfy({ resolved[$0]?.speakerLabel == turn.speakerLabel }) else {
                throw MeetingTranscriptProcessingSchemaError.invalidTurn(turn.id)
            }
        }
        if let missing = visibleIDs.subtracting(seen).first {
            throw MeetingTranscriptProcessingSchemaError.missingUtteranceID(missing)
        }

        var correctionIDs: Set<UUID> = []
        var textByRawID = Dictionary(uniqueKeysWithValues: visibleRaw.map { ($0.id, normalized($0.text)) })
        var previousCorrectionOrder = -1
        for correction in value.corrections {
            guard correctionIDs.insert(correction.id).inserted else {
                throw MeetingTranscriptProcessingSchemaError.duplicateCorrectionID(correction.id)
            }
            guard !correction.utteranceIDs.isEmpty,
                  Set(correction.utteranceIDs).count == correction.utteranceIDs.count,
                  correction.confidence.isFinite,
                  (0...1).contains(correction.confidence),
                  !correction.before.isEmpty,
                  !correction.reason.trimmed.isEmpty else {
                throw MeetingTranscriptProcessingSchemaError.invalidCorrection(correction.id)
            }
            for id in correction.utteranceIDs where !visibleIDs.contains(id) {
                if allRaw[id]?.suppressed == true {
                    throw MeetingTranscriptProcessingSchemaError.suppressedUtteranceID(id)
                }
                throw MeetingTranscriptProcessingSchemaError.unknownUtteranceID(id)
            }
            let correctionOrders = correction.utteranceIDs.compactMap { rawOrder[$0] }
            guard correctionOrders == correctionOrders.sorted(),
                  let correctionOrder = correctionOrders.first,
                  correctionOrder >= previousCorrectionOrder else {
                throw MeetingTranscriptProcessingSchemaError.invalidCorrection(correction.id)
            }
            previousCorrectionOrder = correctionOrder
            let current = correction.utteranceIDs.compactMap { textByRawID[$0] }
                .joined(separator: " ")
            guard current.contains(correction.before) else {
                throw MeetingTranscriptProcessingSchemaError.invalidCorrection(correction.id)
            }
            try validateChange(correction, terminology: terminology, attempt: attempt)
            guard let firstID = correction.utteranceIDs.first,
                  correction.utteranceIDs.count == 1,
                  let original = textByRawID[firstID] else {
                // Cross-utterance corrections can document boundaries but cannot
                // silently rewrite raw utterance content.
                guard correction.kind == .turnBoundary,
                      correction.before == correction.after else {
                    throw MeetingTranscriptProcessingSchemaError.invalidCorrection(correction.id)
                }
                continue
            }
            textByRawID[firstID] = original.replacingFirst(
                correction.before,
                with: correction.after
            )
        }

        for turn in value.turns {
            let expected = turn.utteranceIDs.compactMap { textByRawID[$0] }.joined(separator: " ")
            guard normalized(turn.text) == normalized(expected) else {
                throw MeetingTranscriptProcessingSchemaError.inventedContent(turn.id)
            }
            let hasUnclearMarker = turn.text.localizedCaseInsensitiveContains("[unclear]")
            guard turn.unclear == hasUnclearMarker else {
                throw MeetingTranscriptProcessingSchemaError.invalidTurn(turn.id)
            }
        }
    }

    private static func validateChange(
        _ correction: MeetingTranscriptCorrection,
        terminology: [String],
        attempt: MeetingTranscriptAttempt
    ) throws {
        switch correction.kind {
        case .terminology:
            guard terminology.contains(where: {
                correction.after.localizedCaseInsensitiveContains($0)
                    || $0.localizedCaseInsensitiveContains(correction.after)
            }) else {
                throw MeetingTranscriptProcessingSchemaError.inventedContent(correction.id)
            }
        case .hallucination:
            guard correction.after.trimmed.isEmpty,
                  hasNonSpeechEvidence(for: correction.utteranceIDs, attempt: attempt) else {
                throw MeetingTranscriptProcessingSchemaError.unsupportedHallucinationRemoval(
                    correction.id
                )
            }
        case .punctuation:
            guard lexicalWords(correction.before) == lexicalWords(correction.after) else {
                throw MeetingTranscriptProcessingSchemaError.inventedContent(correction.id)
            }
        case .grammar:
            let introduced = lexicalWords(correction.after).subtracting(lexicalWords(correction.before))
            guard !introduced.contains(where: { token in
                correction.after.split(whereSeparator: \.isWhitespace).contains { word in
                    word.first?.isUppercase == true && lexicalWords(String(word)).contains(token)
                }
            }) else {
                throw MeetingTranscriptProcessingSchemaError.inventedContent(correction.id)
            }
        case .turnBoundary:
            guard correction.before == correction.after else {
                throw MeetingTranscriptProcessingSchemaError.invalidCorrection(correction.id)
            }
        case .unclearAudio:
            guard correction.after.localizedCaseInsensitiveContains("[unclear]") else {
                throw MeetingTranscriptProcessingSchemaError.invalidCorrection(correction.id)
            }
        }
    }

    private static func hasNonSpeechEvidence(
        for utteranceIDs: [UUID],
        attempt: MeetingTranscriptAttempt
    ) -> Bool {
        let referenced = attempt.utterances.filter { utteranceIDs.contains($0.id) }
        return referenced.contains { utterance in
            attempt.spanOutcomes.contains { span in
                span.source.rawValue == utterance.source.rawValue
                    && span.attemptedStartMilliseconds < utterance.endMilliseconds
                    && span.attemptedEndMilliseconds > utterance.startMilliseconds
                    && !span.speechEvidence.isSpeechBearing
            }
        }
    }

    private static func validateShape(_ root: [String: Any]) -> Bool {
        guard Set(root.keys) == [
            "version", "rawAttemptID", "terminologyHash", "turns", "bullets", "corrections",
        ], root["version"] is NSNumber,
           root["rawAttemptID"] is String,
           root["terminologyHash"] is String,
           let turns = root["turns"] as? [[String: Any]],
           let bullets = root["bullets"] as? [String],
           let corrections = root["corrections"] as? [[String: Any]],
           bullets.count <= maximumBullets else { return false }
        let turnKeys: Set<String> = [
            "id", "utteranceIDs", "startMilliseconds", "endMilliseconds",
            "speakerID", "speakerLabel", "text", "unclear",
        ]
        guard turns.allSatisfy({ turn in
            Set(turn.keys) == turnKeys
                && turn["id"] is String
                && turn["utteranceIDs"] is [String]
                && turn["startMilliseconds"] is NSNumber
                && turn["endMilliseconds"] is NSNumber
                && turn["speakerID"] is String
                && turn["speakerLabel"] is String
                && turn["text"] is String
                && turn["unclear"] is Bool
        }) else { return false }
        let correctionKeys: Set<String> = [
            "id", "utteranceIDs", "kind", "before", "after", "reason", "confidence",
        ]
        return corrections.allSatisfy { correction in
            Set(correction.keys) == correctionKeys
                && correction["id"] is String
                && correction["utteranceIDs"] is [String]
                && correction["kind"] is String
                && correction["before"] is String
                && correction["after"] is String
                && correction["reason"] is String
                && correction["confidence"] is NSNumber
        }
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func lexicalWords(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        var value = self
        value.replaceSubrange(range, with: replacement)
        return value
    }
}
