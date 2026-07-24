import Foundation

struct MeetingDetectedApplication: Equatable, Hashable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let displayName: String

    init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        displayName: String
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

struct MeetingDetectorObservation: Equatable, Sendable {
    /// Processes which macOS currently reports as using an audio input device.
    let microphoneUsers: [MeetingDetectedApplication]
    /// Speech evidence from the system-audio activity detector. This is a
    /// boolean signal only; observing it never opens an audio capture stream.
    let isSystemSpeechActive: Bool

    init(
        microphoneUsers: [MeetingDetectedApplication],
        isSystemSpeechActive: Bool
    ) {
        self.microphoneUsers = microphoneUsers
        self.isSystemSpeechActive = isSystemSpeechActive
    }
}

enum MeetingStartCandidateReason: String, Equatable, Sendable {
    case knownConferencingApplication
    case sustainedSystemSpeech
}

struct MeetingStartCandidate: Equatable, Sendable {
    let application: MeetingDetectedApplication
    let reason: MeetingStartCandidateReason
    let suggestedAt: Date
}

enum MeetingDetectorEvent: Equatable, Sendable {
    case startCandidate(MeetingStartCandidate)
    case endCandidate(suggestedAt: Date)
}

@MainActor
protocol MeetingDetecting: AnyObject {
    func observe(_ observation: MeetingDetectorObservation, at date: Date) -> MeetingDetectorEvent?
    func beginTracking(_ application: MeetingDetectedApplication?)
    func dismiss(_ candidate: MeetingStartCandidate)
    func suppressEndSuggestions(until date: Date)
    func reset()
}

/// Converts microphone-use and speech-activity observations into suggestions.
/// It never owns or opens the microphone or system-audio capture streams.
@MainActor
final class MeetingDetector: MeetingDetecting {
    static let knownConferencingBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.FaceTime",
    ]
    static let sustainedSpeechDuration: TimeInterval = 10
    static let endSilenceDuration: TimeInterval = 15

    private let ownProcessIdentifier: Int32
    private var trackedApplication: MeetingDetectedApplication?
    private var isTrackingManualMeeting = false
    private var sustainedSpeechBeganAt: Date?
    private var sustainedSpeechApplication: MeetingDetectedApplication?
    private var emittedStartApplication: MeetingDetectedApplication?
    private var dismissedApplication: MeetingDetectedApplication?
    private var endSilenceBeganAt: Date?
    private var endSuggestionWasEmitted = false
    private var endSuggestionsSuppressedUntil: Date?

    init(ownProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    func observe(
        _ observation: MeetingDetectorObservation,
        at date: Date
    ) -> MeetingDetectorEvent? {
        let microphoneUsers = observation.microphoneUsers
            .filter { $0.processIdentifier != ownProcessIdentifier }

        if trackedApplication != nil || isTrackingManualMeeting {
            return observeEnd(
                microphoneUsers: microphoneUsers,
                isSystemSpeechActive: observation.isSystemSpeechActive,
                at: date
            )
        }

        return observeStart(
            microphoneUsers: microphoneUsers,
            isSystemSpeechActive: observation.isSystemSpeechActive,
            at: date
        )
    }

    func beginTracking(_ application: MeetingDetectedApplication?) {
        trackedApplication = application
        isTrackingManualMeeting = application == nil
        clearStartEvidence()
        clearEndEvidence()
    }

    func dismiss(_ candidate: MeetingStartCandidate) {
        dismissedApplication = candidate.application
        emittedStartApplication = nil
        sustainedSpeechBeganAt = nil
        sustainedSpeechApplication = nil
    }

    func suppressEndSuggestions(until date: Date) {
        endSuggestionsSuppressedUntil = date
        endSuggestionWasEmitted = false
    }

    func reset() {
        trackedApplication = nil
        isTrackingManualMeeting = false
        dismissedApplication = nil
        clearStartEvidence()
        clearEndEvidence()
    }

    private func observeStart(
        microphoneUsers: [MeetingDetectedApplication],
        isSystemSpeechActive: Bool,
        at date: Date
    ) -> MeetingDetectorEvent? {
        if let dismissedApplication,
           !microphoneUsers.contains(where: { Self.isSameProcess($0, dismissedApplication) }) {
            self.dismissedApplication = nil
        }

        let eligibleUsers = microphoneUsers.filter { application in
            guard let dismissedApplication else { return true }
            return !Self.isSameProcess(application, dismissedApplication)
        }

        if let knownApplication = eligibleUsers.first(where: { application in
            application.bundleIdentifier.map(
                Self.knownConferencingBundleIdentifiers.contains
            ) ?? false
        }) {
            clearSustainedSpeechEvidence()
            guard emittedStartApplication != knownApplication else { return nil }
            emittedStartApplication = knownApplication
            return .startCandidate(MeetingStartCandidate(
                application: knownApplication,
                reason: .knownConferencingApplication,
                suggestedAt: date
            ))
        }

        guard isSystemSpeechActive, let application = eligibleUsers.first else {
            clearSustainedSpeechEvidence()
            return nil
        }

        if sustainedSpeechApplication.map({ !Self.isSameProcess($0, application) }) ?? true {
            sustainedSpeechApplication = application
            sustainedSpeechBeganAt = date
        }

        guard let beganAt = sustainedSpeechBeganAt,
              date.timeIntervalSince(beganAt) >= Self.sustainedSpeechDuration,
              emittedStartApplication != application else {
            return nil
        }

        emittedStartApplication = application
        return .startCandidate(MeetingStartCandidate(
            application: application,
            reason: .sustainedSystemSpeech,
            suggestedAt: date
        ))
    }

    private func observeEnd(
        microphoneUsers: [MeetingDetectedApplication],
        isSystemSpeechActive: Bool,
        at date: Date
    ) -> MeetingDetectorEvent? {
        let meetingMicrophoneIsActive: Bool
        if let trackedApplication {
            meetingMicrophoneIsActive = microphoneUsers.contains {
                Self.isSameProcess($0, trackedApplication)
            }
        } else {
            meetingMicrophoneIsActive = !microphoneUsers.isEmpty
        }

        guard !meetingMicrophoneIsActive, !isSystemSpeechActive else {
            clearEndSilenceEvidence()
            return nil
        }

        if endSilenceBeganAt == nil {
            endSilenceBeganAt = date
        }
        guard let endSilenceBeganAt,
              date.timeIntervalSince(endSilenceBeganAt) >= Self.endSilenceDuration,
              !endSuggestionWasEmitted else {
            return nil
        }
        if let suppressedUntil = endSuggestionsSuppressedUntil, date < suppressedUntil {
            return nil
        }

        endSuggestionWasEmitted = true
        return .endCandidate(suggestedAt: date)
    }

    private static func isSameProcess(
        _ lhs: MeetingDetectedApplication,
        _ rhs: MeetingDetectedApplication
    ) -> Bool {
        if lhs.processIdentifier > 0, rhs.processIdentifier > 0 {
            return lhs.processIdentifier == rhs.processIdentifier
        }
        return lhs.bundleIdentifier != nil && lhs.bundleIdentifier == rhs.bundleIdentifier
    }

    private func clearStartEvidence() {
        emittedStartApplication = nil
        dismissedApplication = nil
        clearSustainedSpeechEvidence()
    }

    private func clearSustainedSpeechEvidence() {
        sustainedSpeechBeganAt = nil
        sustainedSpeechApplication = nil
    }

    private func clearEndEvidence() {
        endSuggestionsSuppressedUntil = nil
        clearEndSilenceEvidence()
    }

    private func clearEndSilenceEvidence() {
        endSilenceBeganAt = nil
        endSuggestionWasEmitted = false
    }
}
