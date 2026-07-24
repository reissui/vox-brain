import AppKit
import SwiftUI

struct BrainWindowSizeGuard: NSViewRepresentable {
    static let preferredSize = NSSize(width: 1_040, height: 720)
    static let minimumSize = NSSize(width: 860, height: 620)
    static let maximumSize = NSSize(width: 1_280, height: 900)

    func makeNSView(context: Context) -> NSView {
        let view = BrainWindowSizingView()
        view.configure = Self.configure
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? BrainWindowSizingView else { return }
        view.configureWindow()
    }

    private static func configure(_ window: NSWindow) {
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: maximumSize)
        let maximum = NSSize(
            width: min(maximumSize.width, visibleFrame.width),
            height: min(maximumSize.height, visibleFrame.height)
        )
        window.contentMinSize = NSSize(
            width: min(minimumSize.width, maximum.width),
            height: min(minimumSize.height, maximum.height)
        )
        window.contentMaxSize = maximum

        let current = window.contentLayoutRect.size
        let bounded = NSSize(
            width: min(max(current.width, window.contentMinSize.width), maximum.width),
            height: min(max(current.height, window.contentMinSize.height), maximum.height)
        )
        if current != bounded {
            window.setContentSize(bounded)
        }
        window.setFrame(
            window.constrainFrameRect(window.frame, to: window.screen),
            display: true
        )
    }
}

private final class BrainWindowSizingView: NSView {
    var configure: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        configure?(window)
    }
}
