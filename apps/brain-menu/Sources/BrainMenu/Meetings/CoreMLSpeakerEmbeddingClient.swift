import CoreML
import Foundation

struct CoreMLSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    var modelURL: URL?

    init(modelURL: URL? = Bundle.main.url(forResource: "SpeakerEncoder", withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    func embed(pcm: [Float], sampleRate: Int) -> [Float]? {
        guard sampleRate == MeetingAudioWriter.sampleRate, !pcm.isEmpty else { return nil }
        guard let modelURL,
              let model = try? MLModel(contentsOf: modelURL) else { return nil }
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: pcm.count)], dataType: .float32) else {
            return nil
        }
        for (index, sample) in pcm.enumerated() {
            array[index] = NSNumber(value: sample)
        }
        let input = try? MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: array)])
        guard let input,
              let out = try? model.prediction(from: input),
              let embedding = out.featureValue(for: "embedding")?.multiArrayValue else {
            return nil
        }
        return (0..<embedding.count).map { embedding[$0].floatValue }
    }
}
