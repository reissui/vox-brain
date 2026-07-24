import Foundation

struct MeetingAnalysisActionItem: Codable, Equatable, Sendable {
    let text: String
    let owner: String?
    let due: String?

    init(text: String, owner: String? = nil, due: String? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
    }
}

struct MeetingAnalysisQuote: Codable, Equatable, Sendable {
    let utteranceID: UUID
    let text: String
}

struct MeetingSpeakerSuggestion: Codable, Equatable, Sendable {
    let utteranceID: UUID
    let suggestedName: String
}

/// A draft value only. Callers may copy either field, but this type deliberately
/// has no delivery, URL, account, or recipient API.
struct MeetingFollowUpDraft: Codable, Equatable, Sendable {
    let subject: String
    let body: String

    var subjectForCopy: String { subject }
    var bodyForCopy: String { body }
}

struct MeetingAnalysis: Codable, Equatable, Sendable {
    let version: Int
    let title: String
    let summary: String
    let topics: [String]
    let decisions: [String]
    let actionItems: [MeetingAnalysisActionItem]
    let risks: [String]
    let quotes: [MeetingAnalysisQuote]
    let speakerSuggestions: [MeetingSpeakerSuggestion]
    let followUp: MeetingFollowUpDraft

    init(
        version: Int = MeetingAnalysisSchema.currentVersion,
        title: String,
        summary: String,
        topics: [String],
        decisions: [String],
        actionItems: [MeetingAnalysisActionItem],
        risks: [String],
        quotes: [MeetingAnalysisQuote],
        speakerSuggestions: [MeetingSpeakerSuggestion],
        followUp: MeetingFollowUpDraft
    ) {
        self.version = version
        self.title = title
        self.summary = summary
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.risks = risks
        self.quotes = quotes
        self.speakerSuggestions = speakerSuggestions
        self.followUp = followUp
    }
}

enum MeetingAnalysisSchemaError: Error, Equatable, Sendable {
    case invalidJSON
    case schemaMismatch
    case unsupportedVersion(Int)
    case unknownUtteranceID(UUID)
    case duplicateSpeakerSuggestion(UUID)
    case fabricatedQuote(UUID)
}

enum MeetingAnalysisSchema {
    static let currentVersion = 1

    /// Kept as a checked-in literal so every provider receives exactly the same
    /// versioned contract. All objects are closed and every collection is
    /// present, even when it is empty.
    static let jsonSchema = Data(#"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "properties": {
        "version": { "type": "integer", "const": 1 },
        "title": { "type": "string" },
        "summary": { "type": "string" },
        "topics": { "type": "array", "items": { "type": "string" } },
        "decisions": { "type": "array", "items": { "type": "string" } },
        "actionItems": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": { "type": "string" },
              "owner": { "type": ["string", "null"] },
              "due": { "type": ["string", "null"] }
            },
            "required": ["text", "owner", "due"],
            "additionalProperties": false
          }
        },
        "risks": { "type": "array", "items": { "type": "string" } },
        "quotes": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "utteranceID": { "type": "string", "format": "uuid" },
              "text": { "type": "string" }
            },
            "required": ["utteranceID", "text"],
            "additionalProperties": false
          }
        },
        "speakerSuggestions": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "utteranceID": { "type": "string", "format": "uuid" },
              "suggestedName": { "type": "string" }
            },
            "required": ["utteranceID", "suggestedName"],
            "additionalProperties": false
          }
        },
        "followUp": {
          "type": "object",
          "properties": {
            "subject": { "type": "string" },
            "body": { "type": "string" }
          },
          "required": ["subject", "body"],
          "additionalProperties": false
        }
      },
      "required": [
        "version", "title", "summary", "topics", "decisions", "actionItems",
        "risks", "quotes", "speakerSuggestions", "followUp"
      ],
      "additionalProperties": false
    }
    """#.utf8)

    static func decode(
        _ data: Data,
        validUtteranceIDs: Set<UUID>
    ) throws -> MeetingAnalysis {
        let analysis = try decodeShapeAndVersion(data)

        for quote in analysis.quotes where !validUtteranceIDs.contains(quote.utteranceID) {
            throw MeetingAnalysisSchemaError.unknownUtteranceID(quote.utteranceID)
        }
        var suggestedIDs: Set<UUID> = []
        for suggestion in analysis.speakerSuggestions {
            guard validUtteranceIDs.contains(suggestion.utteranceID) else {
                throw MeetingAnalysisSchemaError.unknownUtteranceID(suggestion.utteranceID)
            }
            guard suggestedIDs.insert(suggestion.utteranceID).inserted else {
                throw MeetingAnalysisSchemaError.duplicateSpeakerSuggestion(suggestion.utteranceID)
            }
        }
        return analysis
    }

    private static func decodeShapeAndVersion(_ data: Data) throws -> MeetingAnalysis {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MeetingAnalysisSchemaError.invalidJSON
        }
        guard let root = object as? [String: Any], validateShape(root) else {
            throw MeetingAnalysisSchemaError.schemaMismatch
        }

        let analysis: MeetingAnalysis
        do {
            analysis = try JSONDecoder().decode(MeetingAnalysis.self, from: data)
        } catch {
            throw MeetingAnalysisSchemaError.schemaMismatch
        }
        guard analysis.version == currentVersion else {
            throw MeetingAnalysisSchemaError.unsupportedVersion(analysis.version)
        }
        return analysis
    }

    static func decode(_ data: Data, utterances: [MeetingUtterance]) throws -> MeetingAnalysis {
        let included = utterances.filter { !$0.suppressed }
        let byID = Dictionary(uniqueKeysWithValues: included.map { ($0.id, $0.text) })
        let analysis = try decode(data, validUtteranceIDs: Set(byID.keys))
        for quote in analysis.quotes {
            guard let utteranceText = byID[quote.utteranceID],
                  !quote.text.isEmpty,
                  utteranceText.contains(quote.text) else {
                throw MeetingAnalysisSchemaError.fabricatedQuote(quote.utteranceID)
            }
        }
        return analysis
    }

    private static func validateShape(_ root: [String: Any]) -> Bool {
        let topLevelKeys: Set<String> = [
            "version", "title", "summary", "topics", "decisions", "actionItems",
            "risks", "quotes", "speakerSuggestions", "followUp",
        ]
        guard Set(root.keys) == topLevelKeys,
              root["version"] is NSNumber,
              root["title"] is String,
              root["summary"] is String,
              isStringArray(root["topics"]),
              isStringArray(root["decisions"]),
              isStringArray(root["risks"]),
              let actionItems = root["actionItems"] as? [[String: Any]],
              let quotes = root["quotes"] as? [[String: Any]],
              let suggestions = root["speakerSuggestions"] as? [[String: Any]],
              let followUp = root["followUp"] as? [String: Any],
              Set(followUp.keys) == ["subject", "body"],
              followUp["subject"] is String,
              followUp["body"] is String else {
            return false
        }

        guard actionItems.allSatisfy({ item in
            let keys = Set(item.keys)
            guard keys.contains("text"),
                  keys.isSubset(of: ["text", "owner", "due"]),
                  item["text"] is String else { return false }
            if let owner = item["owner"], !(owner is String), !(owner is NSNull) {
                return false
            }
            if let due = item["due"], !(due is String), !(due is NSNull) {
                return false
            }
            return true
        }) else { return false }

        guard quotes.allSatisfy({ item in
            Set(item.keys) == ["utteranceID", "text"]
                && item["utteranceID"] is String
                && item["text"] is String
        }) else { return false }

        return suggestions.allSatisfy { item in
            guard Set(item.keys) == ["utteranceID", "suggestedName"],
                  item["utteranceID"] is String,
                  let suggestedName = item["suggestedName"] as? String else {
                return false
            }
            return !suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func isStringArray(_ value: Any?) -> Bool {
        guard let values = value as? [Any] else { return false }
        return values.allSatisfy { $0 is String }
    }
}
