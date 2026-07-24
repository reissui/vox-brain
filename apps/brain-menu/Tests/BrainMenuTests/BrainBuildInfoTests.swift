import Foundation
import Testing
@testable import BrainMenu

struct BrainBuildInfoTests {
    private let sourceSHA = "0123456789abcdef0123456789abcdef01234567"
    private let buildDate = "2026-07-22T12:34:56Z"

    @Test
    func completeProvenanceProducesVersionLabelAndCopySafeDiagnostics() throws {
        let info = try #require(BrainBuildInfo(infoDictionary: validInfoDictionary()))

        #expect(info.version == "1.2.3")
        #expect(info.build == "456")
        #expect(info.sourceSHA == sourceSHA)
        #expect(info.shortSourceSHA == "0123456789ab")
        #expect(info.channel == .release)
        #expect(info.buildDate == buildDate)
        #expect(info.versionLabel == "Version 1.2.3 (456)")
        #expect(info.diagnostics == "Brain 1.2.3 (456)\nChannel: release\nSource: \(sourceSHA)\nBuilt: \(buildDate)")
        #expect(!info.diagnostics.contains("/Users/"))
    }

    @Test
    func everyProvenanceFieldIsRequired() {
        let valid = validInfoDictionary()
        for key in valid.keys {
            var incomplete = valid
            incomplete.removeValue(forKey: key)
            #expect(BrainBuildInfo(infoDictionary: incomplete) == nil)
        }
    }

    @Test
    func malformedProvenanceIsRejected() {
        let invalidValues: [(key: String, value: String)] = [
            ("CFBundleShortVersionString", "1.2"),
            ("CFBundleShortVersionString", "1.2.3.4"),
            ("CFBundleVersion", "1.2"),
            ("CFBundleVersion", "build-456"),
            ("BrainSourceSHA", "0123"),
            ("BrainSourceSHA", sourceSHA.uppercased()),
            ("BrainChannel", "production"),
            ("BrainChannel", "RELEASE"),
            ("BrainBuildDate", "2026-07-22 12:34:56Z"),
            ("BrainBuildDate", "2026-07-22T12:34:56+00:00"),
            ("BrainBuildDate", "2026-02-30T12:34:56Z"),
        ]

        for invalid in invalidValues {
            var dictionary = validInfoDictionary()
            dictionary[invalid.key] = invalid.value
            #expect(BrainBuildInfo(infoDictionary: dictionary) == nil)
        }
    }

    private func validInfoDictionary() -> [String: Any] {
        [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
            "BrainSourceSHA": sourceSHA,
            "BrainChannel": "release",
            "BrainBuildDate": buildDate,
        ]
    }
}
