import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct EndToEndAcceptanceTests {
    @Test
    func shippedApplicationUsesOneLocalRuntime() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtime = try String(
            contentsOf: root.appendingPathComponent("Sources/BrainMenu/Core/BrainRuntime.swift"),
            encoding: .utf8
        )
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("Sources/BrainMenu/Views/DashboardView.swift"),
            encoding: .utf8
        )

        #expect(runtime.contains("LocalBrainClient"))
        #expect(!runtime.contains("BrainAPIClient"))
        #expect(!dashboard.contains("PairBrainView"))
    }
}
