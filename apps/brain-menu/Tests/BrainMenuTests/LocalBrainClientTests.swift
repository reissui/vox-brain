import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct LocalBrainClientTests {
    @Test
    func initializesCapturesSearchesAndRunsFixedCLIJobsWithoutRemoteConfiguration() async throws {
        let fixture = try LocalBrainFixture()
        defer { fixture.remove() }

        try await LocalBrainClient.initialize(fixture.configuration)
        let client = try LocalBrainClient(configuration: fixture.configuration)

        let initial = try await client.status()
        #expect(initial.vault.path.hasSuffix("/\(fixture.root.lastPathComponent)/Vault"))
        #expect(FileManager.default.fileExists(atPath: initial.vault.path))
        #expect(initial.counts.inbox == 0)
        #expect(client.pairedInstance?.instanceID == "local")

        let noteID = try #require(UUID(uuidString: "123e4567-e89b-42d3-a456-426614174000"))
        let receipt = try await client.capture(
            BrainCaptureRequest(
                type: .note,
                text: "A local-only capture with exact text.",
                source: "Brain.app"
            ),
            idempotencyKey: noteID
        )
        #expect(receipt.state == "queued")
        #expect(try await client.captureStatus(id: receipt.id).state == .delivered)

        let imageID = try #require(UUID(uuidString: "123e4567-e89b-42d3-a456-426614174001"))
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
        _ = try await client.capture(
            BrainCaptureRequest(
                type: .design,
                text: "A local screenshot.",
                source: "Brain.app",
                image: "data:image/png;base64,\(png.base64EncodedString())"
            ),
            idempotencyKey: imageID
        )

        let notePath = fixture.vault.appendingPathComponent(
            "inbox/2026-07-24-000000 123e4567 note.md"
        )
        let capturedNotes = try FileManager.default.contentsOfDirectory(
            at: fixture.vault.appendingPathComponent("inbox"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "README.md" }
        #expect(capturedNotes.count == 2)
        #expect(!FileManager.default.fileExists(atPath: notePath.path))
        let note = try #require(capturedNotes.first {
            (try? String(contentsOf: $0, encoding: .utf8).contains(noteID.uuidString.lowercased()))
                == true
        })
        let noteText = try String(contentsOf: note, encoding: .utf8)
        #expect(noteText.contains("via: local"))
        #expect(noteText.hasSuffix("A local-only capture with exact text."))

        let attachments = try FileManager.default.contentsOfDirectory(
            at: fixture.vault.appendingPathComponent("system/attachments"),
            includingPropertiesForKeys: nil
        )
        #expect(attachments.count == 1)
        #expect(attachments[0].lastPathComponent.hasPrefix(imageID.uuidString.lowercased()))
        let attachmentMode = try FileManager.default.attributesOfItem(
            atPath: attachments[0].path
        )[.posixPermissions] as? NSNumber
        #expect(attachmentMode?.intValue == 0o600)

        let search = try await client.searchKnowledge(
            query: "local-only capture",
            limit: 10
        )
        #expect(search.results.count == 1)
        let document = try await client.knowledgeDocument(path: search.results[0].path)
        #expect(document.content.contains("A local-only capture with exact text."))

        let current = try await client.status()
        #expect(current.counts.inbox == 2)
    }

    @Test
    func persistedModeBuildsLocalFactoriesAndAnEmptyProcessJobCompletesLocally() async throws {
        let fixture = try LocalBrainFixture()
        defer { fixture.remove() }
        try await LocalBrainClient.initialize(fixture.configuration)

        let suite = "LocalBrainClientTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try BrainRuntime.persistLocal(fixture.configuration, defaults: defaults)

        #expect(BrainRuntime.deploymentMode(defaults: defaults) == .local)
        #expect(BrainRuntime.statusClient(defaults: defaults) != nil)
        #expect(BrainRuntime.captureClient(defaults: defaults) != nil)
        #expect(BrainRuntime.knowledgeClient(defaults: defaults) != nil)
        #expect(BrainRuntime.jobClient(defaults: defaults) != nil)
        #expect(BrainRuntime.chatClient(defaults: defaults) != nil)

        let client = try LocalBrainClient(configuration: fixture.configuration)
        let created = try await client.createJob(kind: .process, question: nil)
        #expect(created.state == .completed)
        let status = try await client.jobStatus(id: created.id)
        #expect(status.state == .completed)
        #expect(status.output?.contains("inbox is empty") == true)
    }

    @Test
    func localReadsRejectSymlinkEscapesAndCaptureRejectsOversizedImages() async throws {
        let fixture = try LocalBrainFixture()
        defer { fixture.remove() }
        try await LocalBrainClient.initialize(fixture.configuration)
        let client = try LocalBrainClient(configuration: fixture.configuration)

        let outside = fixture.root.appendingPathComponent("outside.md")
        try Data("# Outside\nprivate".utf8).write(to: outside)
        let escape = fixture.vault.appendingPathComponent("notes/escape.md")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        await #expect(throws: LocalBrainError.documentNotFound) {
            _ = try await client.knowledgeDocument(path: "notes/escape.md")
        }

        let oversized = Data(
            repeating: 0x41,
            count: LocalBrainClient.maximumCaptureObjectBytes + 1
        )
        await #expect(throws: LocalBrainError.invalidCapture) {
            _ = try await client.capture(
                BrainCaptureRequest(
                    type: .design,
                    source: "Brain.app",
                    image: "data:image/png;base64,\(oversized.base64EncodedString())"
                ),
                idempotencyKey: UUID()
            )
        }
    }
}

private struct LocalBrainFixture {
    let root: URL
    let vault: URL
    let configuration: BrainLocalConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalBrainClientTests-\(UUID().uuidString)", isDirectory: true)
        vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        configuration = BrainLocalConfiguration(
            vaultPath: vault.path,
            cliPath: repository.appendingPathComponent("scripts/brain").path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
