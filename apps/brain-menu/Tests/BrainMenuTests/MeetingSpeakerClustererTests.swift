import Foundation
import Testing
@testable import BrainMenu

struct MeetingSpeakerClustererTests {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test
    func twoOrthogonalVoicesBecomeRemote2And3InFirstAppearanceOrder() {
        let map = MeetingSpeakerClusterer().cluster([
            .init(id: c, startMilliseconds: 2_000, vector: [0, 1]),
            .init(id: a, startMilliseconds: 0, vector: [1, 0]),
            .init(id: b, startMilliseconds: 1_000, vector: [1, 0]),
        ])
        #expect(map[a] == "remote-2")
        #expect(map[b] == "remote-2")
        #expect(map[c] == "remote-3")
    }

    @Test
    func identicalVectorsStayOneClusterAndWriteNothing() {
        let map = MeetingSpeakerClusterer().cluster([
            .init(id: a, startMilliseconds: 0, vector: [1, 1]),
            .init(id: b, startMilliseconds: 1_000, vector: [2, 2]),
        ])
        #expect(map.isEmpty)
    }

    @Test
    func oneEmbeddingWritesNothing() {
        let map = MeetingSpeakerClusterer().cluster([
            .init(id: a, startMilliseconds: 0, vector: [1, 0]),
        ])
        #expect(map.isEmpty)
    }
}
