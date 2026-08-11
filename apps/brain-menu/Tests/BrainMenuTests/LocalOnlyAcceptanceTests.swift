import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct LocalOnlyAcceptanceTests {
    @MainActor
    @Test
    func isolatedVaultSupportsTheCompleteLocalProductWithoutRemoteConfiguration() async throws {
        let fixture = try LocalOnlyFixture()
        defer { fixture.remove() }
        let defaults = try #require(UserDefaults(suiteName: fixture.defaultsSuite))
        defer { defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        // Obsolete settings may remain on disk, but the local runtime ignores
        // them and never removes user-owned historical configuration.
        defaults.set("remote", forKey: "brain.deployment.mode")
        defaults.set(Data("former-pairing".utf8), forKey: "brain.remote.metadata")

        try await LocalBrainClient.initialize(fixture.configuration)
        try BrainRuntime.persistLocal(fixture.configuration, defaults: defaults)
        let client = try #require(BrainRuntime.client(defaults: defaults))

        let store = BrainStore(
            client: client,
            refreshInterval: .seconds(3_600),
            defaults: defaults
        )
        await store.refresh()
        #expect(store.isReady)
        #expect(store.status?.vault.path == fixture.vault.path)
        #expect(defaults.string(forKey: "brain.deployment.mode") == "remote")
        #expect(defaults.data(forKey: "brain.remote.metadata") == Data("former-pairing".utf8))

        let noteText = "A local note captured exactly."
        _ = try await client.capture(
            BrainCaptureRequest(type: .note, text: noteText, source: "Brain.app"),
            idempotencyKey: UUID()
        )
        let noteEnvelope = try String(
            contentsOf: fixture.vault.appendingPathComponent("last-ingest.json"),
            encoding: .utf8
        )
        #expect(noteEnvelope.contains(noteText))

        let knowledgeURL = fixture.vault.appendingPathComponent("notes/local-product.md")
        try FileManager.default.createDirectory(
            at: knowledgeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Local Product\n\nKnowledge survives relaunch.".write(
            to: knowledgeURL,
            atomically: true,
            encoding: .utf8
        )
        let listed = try await client.listKnowledge(limit: 50)
        #expect(listed.documents.contains { $0.path == "notes/local-product.md" })
        let search = try await client.searchKnowledge(query: "survives relaunch", limit: 10)
        #expect(search.results.map(\.path) == ["notes/local-product.md"])
        #expect(try await client.knowledgeDocument(path: "notes/local-product.md").content
            .contains("Knowledge survives relaunch."))

        let chat = try await client.createJob(kind: .ask, question: "What is local?")
        let chatStatus = try await client.jobStatus(id: chat.id)
        #expect(chatStatus.state == .completed)
        #expect(chatStatus.output == "Local answer: What is local?")

        let librarian = try await client.createJob(kind: .process, question: nil)
        let librarianStatus = try await client.jobStatus(id: librarian.id)
        #expect(librarianStatus.state == .completed)
        #expect(librarianStatus.output == "Local Librarian completed")

        let finalMeetingText = "# Local meeting\n\n## Transcript\n\nFinal words."
        let meetingReceipt = try await client.capture(
            BrainCaptureRequest(
                type: .transcript,
                source: "Brain.app Meeting",
                transcript: finalMeetingText,
                title: "Local meeting.md"
            ),
            idempotencyKey: UUID()
        )
        #expect(try await client.captureStatus(id: meetingReceipt.id).state == .delivered)
        let meetingEnvelope = try String(
            contentsOf: fixture.vault.appendingPathComponent("last-ingest.json"),
            encoding: .utf8
        )
        #expect(meetingEnvelope.contains("Final words."))
    }
}

private struct LocalOnlyFixture {
    let root: URL
    let vault: URL
    let cli: URL
    let defaultsSuite: String

    var configuration: BrainLocalConfiguration {
        BrainLocalConfiguration(vaultPath: vault.path, cliPath: cli.path)
    }

    init() throws {
        defaultsSuite = "LocalOnlyAcceptanceTests.\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(defaultsSuite, isDirectory: true)
        vault = root.appendingPathComponent("Vault", isDirectory: true)
        cli = root.appendingPathComponent("brain", isDirectory: false)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let script = #"""
        #!/bin/sh
        set -eu
        case "${1:-}" in
          init-data)
            mkdir -p "$BRAIN_DATA_ROOT/inbox" "$BRAIN_DATA_ROOT/notes"
            : > "$BRAIN_DATA_ROOT/.brain-data-root"
            ;;
          status)
            printf '%s\n' '{"schema_version":1,"generated_at":"2026-08-11T12:00:00Z","vault":{"path":"'"$BRAIN_DATA_ROOT"'","state":"clean","dirty_paths":0},"counts":{"inbox":0,"sources":0,"notes":0,"people":0,"projects":0},"last_run":null,"services":[]}'
            ;;
          doctor)
            printf '%s\n' '{"schema_version":1,"generated_at":"2026-08-11T12:00:00Z","overall":"healthy","counts":{"pass":1,"activity":0,"warning":0,"failure":0},"checks":[]}'
            ;;
          ingest)
            cat > "$BRAIN_DATA_ROOT/last-ingest.json"
            ;;
          ask)
            printf 'Local answer: %s\n' "${2:-}"
            ;;
          process)
            printf '%s\n' 'Local Librarian completed'
            ;;
          digest)
            printf '%s\n' 'Local digest completed'
            ;;
          *)
            printf 'unsupported command\n' >&2
            exit 2
            ;;
        esac
        """#
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
