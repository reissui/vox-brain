import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("BrainUpdater: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4,
      let parentPID = pid_t(CommandLine.arguments[3]) else {
    fail("invalid arguments")
}

let fileManager = FileManager.default
let current = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let prepared = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let parent = current.deletingLastPathComponent()

guard current.pathExtension == "app",
      prepared.pathExtension == "app",
      prepared.deletingLastPathComponent() == parent,
      prepared.lastPathComponent.hasPrefix(".Brain-update-ready-"),
      fileManager.fileExists(atPath: current.path),
      fileManager.fileExists(atPath: prepared.path) else {
    fail("unsafe update paths")
}

for _ in 0..<300 where kill(parentPID, 0) == 0 {
    usleep(100_000)
}
guard kill(parentPID, 0) != 0 else {
    try? fileManager.removeItem(at: prepared)
    fail("Brain did not quit")
}

let backup = parent.appendingPathComponent(
    ".Brain-update-backup-\(UUID().uuidString).app",
    isDirectory: true
)

do {
    try fileManager.moveItem(at: current, to: backup)
    do {
        try fileManager.moveItem(at: prepared, to: current)
    } catch {
        try? fileManager.moveItem(at: backup, to: current)
        throw error
    }
} catch {
    try? fileManager.removeItem(at: prepared)
    fail(error.localizedDescription)
}

let opener = Process()
opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
opener.arguments = [current.path]
try? opener.run()
opener.waitUntilExit()
sleep(2)
try? fileManager.removeItem(at: backup)
