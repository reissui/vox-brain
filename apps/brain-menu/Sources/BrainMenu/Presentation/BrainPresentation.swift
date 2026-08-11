import Foundation
import SwiftUI

enum BrainPresentationTone: Equatable, Sendable {
    case neutral
    case healthy
    case activity
    case warning
    case failure
}

struct BrainStatePresentation: Equatable, Sendable {
    let symbolName: String
    let label: String
    let accessibilityLabel: String
    let tone: BrainPresentationTone
}

struct BrainFreshnessPresentation: Equatable, Sendable {
    let label: String
    let accessibilityLabel: String
    let isStale: Bool
}

/// One stable spoken and visual vocabulary for transient states shared by the
/// app's capture, speech, meeting, and local-service surfaces.
enum BrainWorkflowAccessibilityState: String, CaseIterable, Equatable, Sendable {
    case listening
    case transcribing
    case locked
    case applyingModel
    case microphoneMissing
    case queued
    case waiting
    case delivered
    case failed
    case serviceHealthy
    case serviceUnavailable

    var presentation: BrainStatePresentation {
        switch self {
        case .listening:
            BrainStatePresentation(
                symbolName: "waveform",
                label: "Listening",
                accessibilityLabel: "Speech status: Listening",
                tone: .activity
            )
        case .transcribing:
            BrainStatePresentation(
                symbolName: "text.bubble",
                label: "Transcribing",
                accessibilityLabel: "Speech status: Transcribing",
                tone: .activity
            )
        case .locked:
            BrainStatePresentation(
                symbolName: "lock.fill",
                label: "Locked",
                accessibilityLabel: "Speech status: Locked continuous dictation",
                tone: .activity
            )
        case .applyingModel:
            BrainStatePresentation(
                symbolName: "arrow.triangle.2.circlepath",
                label: "Applying model",
                accessibilityLabel: "Speech model status: Applying",
                tone: .activity
            )
        case .microphoneMissing:
            BrainStatePresentation(
                symbolName: "mic.slash.fill",
                label: "Microphone missing",
                accessibilityLabel: "Microphone status: Missing",
                tone: .failure
            )
        case .queued:
            BrainStatePresentation(
                symbolName: "clock",
                label: "Queued",
                accessibilityLabel: "Capture status: Queued",
                tone: .activity
            )
        case .waiting:
            BrainStatePresentation(
                symbolName: "hourglass",
                label: "Waiting",
                accessibilityLabel: "Capture status: Waiting for local processing",
                tone: .warning
            )
        case .delivered:
            BrainStatePresentation(
                symbolName: "checkmark.circle.fill",
                label: "Delivered",
                accessibilityLabel: "Capture status: Delivered",
                tone: .healthy
            )
        case .failed:
            BrainStatePresentation(
                symbolName: "exclamationmark.triangle.fill",
                label: "Failed",
                accessibilityLabel: "Status: Failed",
                tone: .failure
            )
        case .serviceHealthy:
            BrainStatePresentation(
                symbolName: "checkmark.circle.fill",
                label: "Service healthy",
                accessibilityLabel: "Service health: Healthy",
                tone: .healthy
            )
        case .serviceUnavailable:
            BrainStatePresentation(
                symbolName: "questionmark.circle",
                label: "Service unavailable",
                accessibilityLabel: "Service health: Unavailable",
                tone: .warning
            )
        }
    }
}

private struct BrainAccessibleStatusModifier: ViewModifier {
    let state: BrainWorkflowAccessibilityState
    let detail: String?

    func body(content: Content) -> some View {
        let presentation = state.presentation
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(detail ?? presentation.label)
    }
}

extension View {
    func brainAccessibleStatus(
        _ state: BrainWorkflowAccessibilityState,
        detail: String? = nil
    ) -> some View {
        modifier(BrainAccessibleStatusModifier(state: state, detail: detail))
    }
}

enum DashboardScope: Int, CaseIterable, Identifiable, Sendable {
    case localVault
    case captureDelivery
    case librarianAutomation
    case systemServices

    var id: Self { self }

    var title: String {
        switch self {
        case .localVault: "Local vault"
        case .captureDelivery: "Capture delivery"
        case .librarianAutomation: "Librarian automation"
        case .systemServices: "System services"
        }
    }

    var symbolName: String {
        switch self {
        case .localVault: "books.vertical"
        case .captureDelivery: "tray.and.arrow.down"
        case .librarianAutomation: "clock.arrow.2.circlepath"
        case .systemServices: "gearshape.2"
        }
    }

    fileprivate static func classify(_ check: BrainHealthCheck) -> Self {
        let scope = check.scope
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        switch scope {
        case "vault", "knowledge":
            return .localVault
        case "capture", "capture-delivery", "delivery", "inbox", "sync":
            return .captureDelivery
        case "automation", "librarian", "scheduler", "agent":
            return .librarianAutomation
        default:
            return .systemServices
        }
    }
}

struct DashboardCheckGroup: Identifiable, Equatable, Sendable {
    let scope: DashboardScope
    let checks: [BrainHealthCheck]

    var id: DashboardScope { scope }
}

enum BrainPresentation {
    static func dictationTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func state(for state: BrainOverallState) -> BrainStatePresentation {
        switch state {
        case .healthy:
            BrainStatePresentation(
                symbolName: "brain.head.profile",
                label: "Healthy",
                accessibilityLabel: "Brain is healthy",
                tone: .healthy
            )
        case .activity:
            BrainStatePresentation(
                symbolName: "arrow.triangle.2.circlepath",
                label: "Activity",
                accessibilityLabel: "Brain has pending activity",
                tone: .activity
            )
        case .warning:
            BrainStatePresentation(
                symbolName: "exclamationmark.triangle",
                label: "Warning",
                accessibilityLabel: "Brain has a warning",
                tone: .warning
            )
        case .failure:
            BrainStatePresentation(
                symbolName: "xmark.octagon",
                label: "Failure",
                accessibilityLabel: "Brain has a failure",
                tone: .failure
            )
        }
    }

    static func state(for state: BrainCheckState) -> BrainStatePresentation {
        switch state {
        case .pass:
            self.state(for: BrainOverallState.healthy)
        case .activity:
            self.state(for: BrainOverallState.activity)
        case .warning:
            self.state(for: BrainOverallState.warning)
        case .failure:
            self.state(for: BrainOverallState.failure)
        }
    }

    static func state(for snapshot: BrainSnapshot?) -> BrainStatePresentation {
        guard let snapshot else {
            return BrainStatePresentation(
                symbolName: "brain.head.profile",
                label: "Checking…",
                accessibilityLabel: "Checking Brain status",
                tone: .neutral
            )
        }

        guard !snapshot.isStale else { return staleState }
        return state(for: snapshot.health.overall)
    }

    static func state(
        for snapshot: BrainSnapshot?,
        isReady: Bool
    ) -> BrainStatePresentation {
        guard isReady else { return unconfiguredState }
        return state(for: snapshot)
    }

    static func state(
        for checkState: BrainCheckState,
        in snapshot: BrainSnapshot
    ) -> BrainStatePresentation {
        snapshot.isStale ? staleState : state(for: checkState)
    }

    static func freshness(for snapshot: BrainSnapshot?) -> BrainFreshnessPresentation {
        guard let snapshot else {
            return BrainFreshnessPresentation(
                label: "Waiting for first refresh",
                accessibilityLabel: "Waiting for the first Brain status refresh",
                isStale: false
            )
        }

        if snapshot.isStale {
            return BrainFreshnessPresentation(
                label: "Stale",
                accessibilityLabel: "This status snapshot is stale",
                isStale: true
            )
        }

        return BrainFreshnessPresentation(
            label: "Fresh",
            accessibilityLabel: "This status snapshot is fresh",
            isStale: false
        )
    }

    static func state(
        for group: DashboardCheckGroup,
        in snapshot: BrainSnapshot
    ) -> BrainStatePresentation {
        guard !snapshot.isStale else { return staleState }
        guard let state = group.checks.map(\.state).max(by: {
            severity(of: $0) < severity(of: $1)
        }) else {
            return BrainStatePresentation(
                symbolName: "circle.dashed",
                label: "Not reported",
                accessibilityLabel: "No Brain checks reported",
                tone: .neutral
            )
        }
        return self.state(for: state)
    }

    static func checkGroups(for checks: [BrainHealthCheck]) -> [DashboardCheckGroup] {
        DashboardScope.allCases.map { scope in
            DashboardCheckGroup(
                scope: scope,
                checks: checks.filter { DashboardScope.classify($0) == scope }
            )
        }
    }

    private static let staleState = BrainStatePresentation(
        symbolName: "exclamationmark.triangle",
        label: "Stale",
        accessibilityLabel: "Brain status is stale",
        tone: .warning
    )

    private static let unconfiguredState = BrainStatePresentation(
        symbolName: "internaldrive",
        label: "Local setup needed",
        accessibilityLabel: "Brain local setup is needed",
        tone: .neutral
    )

    private static func severity(of state: BrainCheckState) -> Int {
        switch state {
        case .pass: 0
        case .activity: 1
        case .warning: 2
        case .failure: 3
        }
    }
}
