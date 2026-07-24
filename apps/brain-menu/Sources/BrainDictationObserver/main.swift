import Foundation
import BrainDictationObserverSupport

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--persist-history" {
    let directoryURL = arguments.count == 2
        ? URL(fileURLWithPath: arguments[1], isDirectory: true)
        : nil
    BrainDictationObserver.runPersistenceWorker(directoryURL: directoryURL)
} else {
    _ = BrainDictationObserver.forwardTranscript()
    try? FileHandle.standardOutput.close()
}
