import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct VoxTypeConfigurationTests {
    @Test
    func defaultPathUsesTheMacVoxTypeConfigurationWhenItExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoxTypeDefaultPathTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root
            .appendingPathComponent("Library/Application Support/voxtype", isDirectory: true)
            .appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("[output]\nmode = \"type\"\n".utf8).write(to: legacy)

        let editor = VoxTypeConfigurationEditor(homeDirectoryURL: root)

        #expect(editor.configurationURL == legacy.standardizedFileURL)
    }

    @Test
    func updatesOnlyRequestedEngineAndModelAndCreatesPrivateImmediateBackup() throws {
        let source = """
        # personal settings
        engine = "whisper" # active engine

        [hotkey]
        key = "FN"
        enabled = true

        [whisper]
        model = "small.en" # keep fallback
        language = "en"

        [parakeet]
        model = "parakeet-unified-en-0.6b"
        on_demand_loading = false
        """
        let fixture = try VoxTypeConfigurationFixture(source)
        let selection = SpeechEngineSelection(
            engine: .parakeet,
            modelID: SpeechEngineCatalog.englishDefaultModelID
        )

        let backup = try fixture.editor.apply(selection)

        let saved = try fixture.text()
        #expect(saved.contains("engine = \"parakeet\" # active engine"))
        #expect(saved.contains("[parakeet]\nmodel = \"parakeet-tdt-0.6b-v3\""))
        #expect(saved.contains("[hotkey]\nkey = \"FN\"\nenabled = true"))
        #expect(saved.contains("[whisper]\nmodel = \"small.en\" # keep fallback"))
        #expect(backup.selection == SpeechEngineSelection(engine: .whisper, modelID: "small.en"))
        #expect(try Data(contentsOf: fixture.editor.backupURL) == Data(source.utf8))
        #expect(try fixture.backupPermissions() == 0o600)
    }

    @Test
    func insertsOnlyMissingSupportedTargetsAndPreservesCommentsCRLFAndFinalNewline() throws {
        let source = "# VoxType\r\n[output]\r\ntype_mode = \"type\" # unchanged\r\n"
        let fixture = try VoxTypeConfigurationFixture(source)

        _ = try fixture.editor.apply(SpeechEngineSelection(
            engine: .whisper,
            modelID: SpeechEngineCatalog.multilingualFallbackModelID
        ))

        let saved = try fixture.text()
        #expect(saved.hasPrefix("# VoxType\r\nengine = \"whisper\"\r\n[output]"))
        #expect(saved.contains("type_mode = \"type\" # unchanged"))
        #expect(saved.contains("[whisper]\r\nmodel = \"large-v3-turbo\"\r\n"))
        #expect(saved.hasSuffix("\r\n"))
    }

    @Test
    func rejectsDuplicateOwnedKeysAndUnsafeSelectionsBeforeWriting() throws {
        let cases: [(String, VoxTypeConfigurationError)] = [
            ("engine = \"whisper\"\nengine = \"parakeet\"\n", .duplicateEngineKey),
            ("engine = \"parakeet\"\n[parakeet]\nmodel = \"a\"\n[parakeet]\nmodel = \"b\"\n", .duplicateEngineSection(.parakeet)),
            ("engine = \"whisper\"\n[whisper]\nmodel = \"a\"\nmodel = \"b\"\n", .duplicateModelKey(.whisper)),
        ]
        for (source, expected) in cases {
            let fixture = try VoxTypeConfigurationFixture(source)
            #expect(throws: expected) {
                try fixture.editor.apply(SpeechEngineSelection(
                    engine: .parakeet,
                    modelID: SpeechEngineCatalog.englishDefaultModelID
                ))
            }
            #expect(try fixture.text() == source)
            #expect(!FileManager.default.fileExists(atPath: fixture.editor.backupURL.path))
        }

        let fixture = try VoxTypeConfigurationFixture("engine = \"whisper\"\n")
        #expect(throws: VoxTypeConfigurationError.invalidSelection) {
            try fixture.editor.apply(SpeechEngineSelection(
                engine: .parakeet,
                modelID: "large-v3-turbo"
            ))
        }
    }

    @Test
    func failedAtomicReplacementKeepsOriginalAndRollbackRestoresExactBytes() throws {
        let original = "engine = \"whisper\"\n[whisper]\nmodel = \"small.en\"\n"
        let failedFixture = try VoxTypeConfigurationFixture(original)
        let failing = VoxTypeConfigurationEditor(
            configuredURL: failedFixture.configurationURL
        ) { event in
            if event == .beforeConfigurationReplacement { throw InjectedVoxTypeFailure() }
        }
        #expect(throws: VoxTypeConfigurationError.atomicWriteFailed) {
            try failing.apply(SpeechEngineSelection(
                engine: .parakeet,
                modelID: SpeechEngineCatalog.englishDefaultModelID
            ))
        }
        #expect(try failedFixture.text() == original)
        #expect(try failedFixture.temporaryFiles().isEmpty)

        let fixture = try VoxTypeConfigurationFixture(original)
        let backup = try fixture.editor.apply(SpeechEngineSelection(
            engine: .parakeet,
            modelID: SpeechEngineCatalog.englishDefaultModelID
        ))
        try fixture.editor.rollback(to: backup)
        #expect(try fixture.text() == original)
    }

    @Test
    func refusesSymlinkConfigurationAndBackupWithoutFollowingEither() throws {
        let fixture = try VoxTypeConfigurationFixture(nil)
        let outside = fixture.root.appendingPathComponent("outside.toml")
        try "engine = \"whisper\"".write(to: outside, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.configurationURL,
            withDestinationURL: outside
        )
        #expect(throws: VoxTypeConfigurationError.configurationIsNotRegularFile) {
            try fixture.editor.apply(SpeechEngineSelection(
                engine: .parakeet,
                modelID: SpeechEngineCatalog.englishDefaultModelID
            ))
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "engine = \"whisper\"")

        let backupFixture = try VoxTypeConfigurationFixture(
            "engine = \"whisper\"\n[whisper]\nmodel = \"small.en\"\n"
        )
        let protected = backupFixture.root.appendingPathComponent("protected")
        try "unchanged".write(to: protected, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: backupFixture.editor.backupURL,
            withDestinationURL: protected
        )
        #expect(throws: VoxTypeConfigurationError.unsafeBackup) {
            try backupFixture.editor.apply(SpeechEngineSelection(
                engine: .parakeet,
                modelID: SpeechEngineCatalog.englishDefaultModelID
            ))
        }
        #expect(try String(contentsOf: protected, encoding: .utf8) == "unchanged")
    }

    @Test
    func continuousDurationChangesOnlyTheUniqueAudioValueAtomically() throws {
        let source = """
        # personal settings
        engine = "parakeet"

        [hotkey]
        key = "FN"
        modifiers = ["CONTROL"]
        mode = "push_to_talk"

        [audio]
        device = "default"
        max_duration_secs = 60 # old safety limit
        sample_rate = 16000
        """
        let fixture = try VoxTypeConfigurationFixture(source)

        try fixture.editor.configureMaximumDuration(seconds: 3_600)

        let expected = source.replacingOccurrences(
            of: "max_duration_secs = 60 # old safety limit",
            with: "max_duration_secs = 3600 # old safety limit"
        )
        #expect(try fixture.text() == expected)
        #expect(try fixture.temporaryFiles().isEmpty)
        #expect(try fixture.text().contains(
            "[hotkey]\nkey = \"FN\"\nmodifiers = [\"CONTROL\"]\nmode = \"push_to_talk\""
        ))

        // An already-correct value is a byte-identical no-op.
        try fixture.editor.configureMaximumDuration(seconds: 3_600)
        #expect(try fixture.text() == expected)
    }

    @Test
    func continuousDurationRejectsAmbiguousAudioConfigurationWithoutWriting() throws {
        let cases: [(String, VoxTypeConfigurationError)] = [
            (
                "[audio]\nmax_duration_secs = 60\nmax_duration_secs = 90\n",
                .duplicateMaximumDurationKey
            ),
            (
                "[audio]\nmax_duration_secs = 60\n[audio]\ndevice = \"other\"\n",
                .duplicateAudioSection
            ),
        ]
        for (source, expected) in cases {
            let fixture = try VoxTypeConfigurationFixture(source)
            #expect(throws: expected) {
                try fixture.editor.configureMaximumDuration(seconds: 3_600)
            }
            #expect(try fixture.text() == source)
            #expect(try fixture.temporaryFiles().isEmpty)
        }
    }

}

private struct InjectedVoxTypeFailure: Error {}

private final class VoxTypeConfigurationFixture {
    let root: URL
    let configurationURL: URL

    var editor: VoxTypeConfigurationEditor {
        VoxTypeConfigurationEditor(configuredURL: configurationURL)
    }

    init(_ source: String?) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoxTypeConfigurationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        configurationURL = root.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let source { try Data(source.utf8).write(to: configurationURL) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func text() throws -> String {
        try String(contentsOf: configurationURL, encoding: .utf8)
    }

    func backupPermissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: editor.backupURL.path)
        let value = attributes[FileAttributeKey.posixPermissions] as? NSNumber
        return try #require(value).intValue
    }

    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".brain-tmp") }
    }

    func makeExecutable(named relativePath: String = "BrainDictationObserver") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }
}
