import Foundation

struct MeetingSpeakerClusterer: Sendable {
    static let sameSpeakerCosineThreshold: Float = 0.65

    struct Point: Sendable {
        let id: UUID
        let startMilliseconds: Int64
        let vector: [Float]
    }

    func cluster(_ points: [Point]) -> [UUID: String] {
        let normalized = points.compactMap { point -> Point? in
            guard let vector = Self.l2Normalize(point.vector) else { return nil }
            return Point(id: point.id, startMilliseconds: point.startMilliseconds, vector: vector)
        }
        guard normalized.count >= 2 else { return [:] }

        var parent = Array(normalized.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        func union(_ i: Int, _ j: Int) {
            let a = find(i), b = find(j)
            if a != b { parent[b] = a }
        }

        for i in normalized.indices {
            for j in normalized.indices where j > i {
                if Self.cosine(normalized[i].vector, normalized[j].vector)
                    >= Self.sameSpeakerCosineThreshold {
                    union(i, j)
                }
            }
        }

        var members: [Int: [Point]] = [:]
        for (index, point) in normalized.enumerated() {
            members[find(index), default: []].append(point)
        }
        guard members.count >= 2 else { return [:] }

        let ordered = members.values.sorted { lhs, rhs in
            let l = lhs.map(\.startMilliseconds).min() ?? 0
            let r = rhs.map(\.startMilliseconds).min() ?? 0
            if l != r { return l < r }
            return (lhs.map(\.id.uuidString).min() ?? "") < (rhs.map(\.id.uuidString).min() ?? "")
        }

        var map: [UUID: String] = [:]
        for (offset, group) in ordered.enumerated() {
            let id = MeetingSpeakerIdentity.clusteredID(index: offset + 2)
            for point in group { map[point.id] = id }
        }
        return map
    }

    private static func l2Normalize(_ vector: [Float]) -> [Float]? {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}
