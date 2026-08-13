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

    private enum CodingKeys: String, CodingKey {
        case text
        case owner
        case due
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if let owner {
            try container.encode(owner, forKey: .owner)
        } else {
            try container.encodeNil(forKey: .owner)
        }
        if let due {
            try container.encode(due, forKey: .due)
        } else {
            try container.encodeNil(forKey: .due)
        }
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

    init(
        version: Int = MeetingAnalysisSchema.currentVersion,
        title: String,
        summary: String,
        topics: [String],
        decisions: [String],
        actionItems: [MeetingAnalysisActionItem],
        risks: [String],
        quotes: [MeetingAnalysisQuote],
        speakerSuggestions: [MeetingSpeakerSuggestion]
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
    static let currentVersion = 2

    /// Kept as a checked-in literal so every provider receives exactly the same
    /// versioned contract. All objects are closed and every collection is
    /// present, even when it is empty.
    static let jsonSchema = Data(#"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "properties": {
        "version": { "type": "integer", "const": 2 },
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
        }
      },
      "required": [
        "version", "title", "summary", "topics", "decisions", "actionItems",
        "risks", "quotes", "speakerSuggestions"
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
        guard let root = object as? [String: Any] else {
            throw MeetingAnalysisSchemaError.schemaMismatch
        }

        guard let version = integerVersion(root["version"]) else {
            throw MeetingAnalysisSchemaError.schemaMismatch
        }
        guard version == currentVersion else {
            throw MeetingAnalysisSchemaError.unsupportedVersion(version)
        }
        guard validateCurrentShape(root) else {
            throw MeetingAnalysisSchemaError.schemaMismatch
        }

        let analysis: MeetingAnalysis
        do {
            analysis = try JSONDecoder().decode(MeetingAnalysis.self, from: data)
        } catch {
            throw MeetingAnalysisSchemaError.schemaMismatch
        }
        return analysis
    }

    /// Decodes the durable analysis portion of `analysis.json`. Version 1 was
    /// shipped with a closed follow-up draft object; that field is deliberately
    /// discarded and the returned value is normalized to the current version.
    /// This function does not write the migrated representation back to disk.
    static func decodeStored(_ data: Data) throws -> MeetingAnalysis {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MeetingAnalysisSchemaError.invalidJSON
        }
        guard var root = object as? [String: Any],
              let version = integerVersion(root["version"]) else {
            throw MeetingAnalysisSchemaError.schemaMismatch
        }

        switch version {
        case currentVersion:
            guard validateCurrentShape(root) else {
                throw MeetingAnalysisSchemaError.schemaMismatch
            }
        case 1:
            guard validateLegacyV1Shape(root) else {
                throw MeetingAnalysisSchemaError.schemaMismatch
            }
            root.removeValue(forKey: "followUp")
            root["version"] = currentVersion
        default:
            throw MeetingAnalysisSchemaError.unsupportedVersion(version)
        }

        do {
            let normalized = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            return try JSONDecoder().decode(MeetingAnalysis.self, from: normalized)
        } catch {
            throw MeetingAnalysisSchemaError.schemaMismatch
        }
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

    private static func validateCurrentShape(_ root: [String: Any]) -> Bool {
        let topLevelKeys: Set<String> = [
            "version", "title", "summary", "topics", "decisions", "actionItems",
            "risks", "quotes", "speakerSuggestions",
        ]
        guard Set(root.keys) == topLevelKeys,
              integerVersion(root["version"]) == currentVersion,
              root["title"] is String,
              root["summary"] is String,
              isStringArray(root["topics"]),
              isStringArray(root["decisions"]),
              isStringArray(root["risks"]),
              let actionItems = root["actionItems"] as? [[String: Any]],
              let quotes = root["quotes"] as? [[String: Any]],
              let suggestions = root["speakerSuggestions"] as? [[String: Any]] else {
            return false
        }

        guard actionItems.allSatisfy({ item in
            guard Set(item.keys) == ["text", "owner", "due"],
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

    private static func validateLegacyV1Shape(_ root: [String: Any]) -> Bool {
        let topLevelKeys: Set<String> = [
            "version", "title", "summary", "topics", "decisions", "actionItems",
            "risks", "quotes", "speakerSuggestions", "followUp",
        ]
        guard Set(root.keys) == topLevelKeys,
              integerVersion(root["version"]) == 1,
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

    private static func integerVersion(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.intValue
        guard number.doubleValue == Double(integer) else { return nil }
        return integer
    }

    private static func isStringArray(_ value: Any?) -> Bool {
        guard let values = value as? [Any] else { return false }
        return values.allSatisfy { $0 is String }
    }
}
