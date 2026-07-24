import ApplicationServices
import Foundation

struct SelectedTextSnapshot: Equatable, Sendable {
    let selectedText: String?
    let windowTitle: String
}

enum SelectedTextReaderError: Error, Equatable, LocalizedError, Sendable {
    case accessibilityDenied
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Allow Accessibility for Brain in System Settings, then try Capture again."
        case .sourceUnavailable:
            "Return to the source window and try Capture again."
        }
    }
}

@MainActor
protocol SelectedTextReading: AnyObject {
    /// Reads only the focused application's Accessibility tree. It never
    /// consults the pasteboard or prompts for a privacy permission.
    func snapshot(
        from application: QuickCaptureApplicationIdentity?
    ) throws -> SelectedTextSnapshot
}

@MainActor
final class SystemSelectedTextReader: SelectedTextReading {
    func snapshot(
        from application: QuickCaptureApplicationIdentity?
    ) throws -> SelectedTextSnapshot {
        guard AXIsProcessTrusted() else {
            throw SelectedTextReaderError.accessibilityDenied
        }
        guard let application else {
            throw SelectedTextReaderError.sourceUnavailable
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let window = try requiredElement(
            attribute: kAXFocusedWindowAttribute as CFString,
            from: applicationElement
        )
        guard let title = try optionalString(
            attribute: kAXTitleAttribute as CFString,
            from: window
        ), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectedTextReaderError.sourceUnavailable
        }

        let selectedText: String?
        if let focusedElement = try optionalElement(
            attribute: kAXFocusedUIElementAttribute as CFString,
            from: applicationElement
        ) {
            selectedText = try optionalString(
                attribute: kAXSelectedTextAttribute as CFString,
                from: focusedElement
            )
        } else {
            selectedText = nil
        }
        return SelectedTextSnapshot(selectedText: selectedText, windowTitle: title)
    }

    private func requiredElement(
        attribute: CFString,
        from element: AXUIElement
    ) throws -> AXUIElement {
        guard let value = try optionalElement(attribute: attribute, from: element) else {
            throw SelectedTextReaderError.sourceUnavailable
        }
        return value
    }

    private func optionalElement(
        attribute: CFString,
        from element: AXUIElement
    ) throws -> AXUIElement? {
        guard let value = try optionalValue(attribute: attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw SelectedTextReaderError.sourceUnavailable
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func optionalString(
        attribute: CFString,
        from element: AXUIElement
    ) throws -> String? {
        guard let value = try optionalValue(attribute: attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
            throw SelectedTextReaderError.sourceUnavailable
        }
        return value as? String
    }

    private func optionalValue(
        attribute: CFString,
        from element: AXUIElement
    ) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch status {
        case .success:
            return value
        case .attributeUnsupported, .noValue:
            return nil
        default:
            throw SelectedTextReaderError.sourceUnavailable
        }
    }
}

enum SelectedHTTPURL {
    /// Accepts exactly one explicit HTTP(S) URL and preserves its spelling.
    /// Whitespace is allowed only around the selection, never inside the URL.
    static func parse(_ selection: String?) -> String? {
        guard let selection else { return nil }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: trimmed),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, isValidHost(host),
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              components.url != nil,
              components.user == nil, components.password == nil else {
            return nil
        }
        return trimmed
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix(".") else {
            return false
        }
        return host.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "-"
                || scalar == ":"
                || scalar == "["
                || scalar == "]"
        }
    }
}
