import CoreML
import Foundation

/// Loads the optional on-device speaker encoder once and reuses it for every
/// utterance in a meeting. Compiling a Core ML model is expensive, and a
/// missing or unloadable model must fail closed for the whole run rather than
/// be retried per span.
final class CoreMLSpeakerEmbeddingClient: SpeakerEmbeddingClient, @unchecked Sendable {
    private let modelURL: URL?
    private let lock = NSLock()
    private var cachedModel: MLModel?
    private var loadFailed = false

    init(
        modelURL: URL? = Bundle.main.url(
            forResource: "SpeakerEncoder",
            withExtension: "mlmodelc"
        )
    ) {
        self.modelURL = modelURL
    }

    func embed(pcm: [Float], sampleRate: Int) -> [Float]? {
        guard sampleRate == MeetingAudioWriter.sampleRate,
              !pcm.isEmpty,
              let model = loadedModel(),
              let array = try? MLMultiArray(
                  shape: [1, NSNumber(value: pcm.count)],
                  dataType: .float32
              ) else {
            return nil
        }
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { destination, _ in
            _ = pcm.withUnsafeBufferPointer { source in
                destination.update(from: source)
            }
        }
        guard let input = try? MLDictionaryFeatureProvider(
            dictionary: ["audio": MLFeatureValue(multiArray: array)]
        ),
            let output = try? model.prediction(from: input),
            let embedding = output.featureValue(for: "embedding")?.multiArrayValue,
            embedding.count > 0,
            embedding.dataType == .float32 else {
            return nil
        }
        return embedding.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
    }

    private func loadedModel() -> MLModel? {
        lock.withLock {
            if let cachedModel { return cachedModel }
            guard !loadFailed, let modelURL else { return nil }
            guard let model = try? MLModel(contentsOf: modelURL) else {
                loadFailed = true
                return nil
            }
            cachedModel = model
            return model
        }
    }
}
