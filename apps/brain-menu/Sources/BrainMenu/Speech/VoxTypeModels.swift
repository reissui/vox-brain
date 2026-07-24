import Foundation

enum VoxTypeRuntimeState: String, Codable, CaseIterable, Sendable {
    case idle
    case recording
    case streaming
    case transcribing
    case stopped
}

struct VoxTypeStatusSnapshot: Equatable, Sendable {
    let state: VoxTypeRuntimeState
    let model: String?
    let device: String?
    let backend: String?

    var daemonIsRunning: Bool { state != .stopped }
}

enum VoxTypeUnavailableReason: Equatable, Sendable {
    case daemonNotRunning
    case malformedStatus
    case outputTooLarge
    case timedOut
    case launchFailed
}

enum VoxTypeStatusProcessError: Error, Equatable, Sendable {
    case launchFailed
    case outputTooLarge
}

enum VoxTypeStatus: Equatable, Sendable {
    case available(VoxTypeStatusSnapshot)
    case unavailable(VoxTypeUnavailableReason)

    var snapshot: VoxTypeStatusSnapshot? {
        guard case .available(let snapshot) = self else { return nil }
        return snapshot
    }
}

struct VoxTypeVersion: Equatable, Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    static func < (lhs: VoxTypeVersion, rhs: VoxTypeVersion) -> Bool {
        let lhsCore = (lhs.major, lhs.minor, lhs.patch)
        let rhsCore = (rhs.major, rhs.minor, rhs.patch)
        if lhsCore.0 != rhsCore.0 { return lhsCore.0 < rhsCore.0 }
        if lhsCore.1 != rhsCore.1 { return lhsCore.1 < rhsCore.1 }
        if lhsCore.2 != rhsCore.2 { return lhsCore.2 < rhsCore.2 }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case (.some(let lhs), .some(let rhs)): return lhs < rhs
        }
    }
}

struct VoxTypeHotkeyConfiguration: Equatable, Sendable {
    let key: String
    let modifiers: [String]
    let mode: String

    var shortcutDescription: String {
        let keys = modifiers.map(Self.displayName) + [Self.displayName(key)]
        return "\(keys.joined(separator: "+")) (\(Self.modeDescription(mode)))"
    }

    private static func displayName(_ value: String) -> String {
        switch value.uppercased() {
        case "FN": "Fn"
        case "LEFTCTRL", "RIGHTCTRL", "CTRL", "CONTROL": "Control"
        case "LEFTALT", "RIGHTALT", "ALT", "OPTION": "Option"
        case "LEFTSHIFT", "RIGHTSHIFT", "SHIFT": "Shift"
        case "LEFTMETA", "RIGHTMETA", "META", "COMMAND", "CMD": "Command"
        default: value
        }
    }

    private static func modeDescription(_ value: String) -> String {
        switch value.lowercased() {
        case "pushtotalk", "push_to_talk": "push-to-talk"
        case "toggle": "toggle"
        default: value
        }
    }
}

enum VoxTypeCommand: String, Equatable, Sendable {
    case version
    case configuration
    case status
    case recordStart
    case recordStop
    case recordCancel
    case transcribe
    case modelList
    case modelInstall
}

enum VoxTypeClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidVersion
    case invalidConfiguration
    case daemonUnavailable(VoxTypeUnavailableReason)
    case commandFailed(command: VoxTypeCommand, exitStatus: Int32)
    case invalidEngine
    case invalidAudioFile
    case invalidTranscript
    case invalidModel
    case invalidModelInventory
    case outputTooLarge
    case timedOut(command: VoxTypeCommand)
    case launchFailed(command: VoxTypeCommand)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidVersion:
            "VoxType returned an invalid version."
        case .invalidConfiguration:
            "VoxType returned an invalid configuration."
        case .daemonUnavailable:
            "The VoxType daemon is unavailable."
        case .commandFailed(let command, let exitStatus):
            "The fixed VoxType \(command.rawValue) command failed (status \(exitStatus))."
        case .invalidEngine:
            "The selected VoxType engine identifier is invalid."
        case .invalidAudioFile:
            "VoxType transcription requires an absolute WAV file URL."
        case .invalidTranscript:
            "VoxType returned invalid transcript text."
        case .invalidModel:
            "The selected VoxType model is not in Brain's fixed catalog."
        case .invalidModelInventory:
            "VoxType returned invalid model inventory text."
        case .outputTooLarge:
            "VoxType output exceeded the allowed size."
        case .timedOut(let command):
            "The fixed VoxType \(command.rawValue) command timed out."
        case .launchFailed(let command):
            "The fixed VoxType \(command.rawValue) command could not be launched."
        case .cancelled:
            "The VoxType command was cancelled."
        }
    }
}

struct VoxTypeUnsupportedEngineError: Error, Equatable, LocalizedError, Sendable {
    let engine: String

    var errorDescription: String? {
        "The installed VoxType executable does not support the \(engine) engine."
    }
}

enum VoxTypeDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case unsafeUserSelection

    var errorDescription: String? {
        "Select a regular executable named voxtype."
    }
}

enum VoxTypeOutputStream: Equatable, Sendable {
    case stdout
    case stderr
}

enum VoxTypeProcessError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputLimitExceeded(VoxTypeOutputStream)
    case invalidWorkingDirectory
}

enum VoxTypeProcessScheduling: Equatable, Sendable {
    case normal
    case background
}

struct VoxTypeProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let standardInput: Data?
    let environment: [String: String]
    let timeout: TimeInterval
    let maximumOutputBytes: Int
    let scheduling: VoxTypeProcessScheduling
}

struct VoxTypeProcessOutput: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let exitStatus: Int32

    init(stdout: Data = Data(), stderr: Data = Data(), exitStatus: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    init(stdout: String, stderr: String = "", exitStatus: Int32 = 0) {
        self.init(
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8),
            exitStatus: exitStatus
        )
    }
}
