import AppKit

private enum InputTouchBarID {
    static let preview = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.preview")
}

/// A real (if visually negligible) window holding a real, editable NSTextField.
/// A genuine text field in a genuine key window is what makes macOS route real
/// keystrokes to it — the private "system modal touch bar" API does not support
/// keyboard input for third-party apps, but a real window does.
///
/// `makeTouchBar()` is the standard, fully public API apps use to show custom
/// Touch Bar content while they're key. Providing our own here (echoing the
/// live text as it's typed) takes priority over the system's default
/// text-completion candidate bar, which only shows predictive suggestions and
/// never echoes the raw text — no good when the field itself isn't on screen.
final class InputWindow: NSWindow, NSTouchBarDelegate {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    let textField: NSTextField
    private let previewLabel = MarqueeLabel(frame: NSRect(x: 0, y: 0, width: 280, height: 30))

    init() {
        // A more realistically-sized field (rather than a degenerate 4x4 one)
        // gives the system enough context to treat this as a genuine editing session.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        field.font = .systemFont(ofSize: 13)
        self.textField = field

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        hasShadow = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        // Not alpha 0 / off-screen: a truly invisible or off-screen window may
        // not be treated as a real interactive surface by WindowServer.
        // Transparent background + no shadow removes the visible flash while
        // the window remains "real" at the very top screen edge.
        setFrameOrigin(NSPoint(x: 0, y: NSScreen.main?.frame.height ?? 0))
        contentView?.addSubview(field)
    }

    func updatePreview(_ text: String) {
        previewLabel.text = text.isEmpty ? "Scrivi la domanda…" : text
    }

    override func makeTouchBar() -> NSTouchBar? {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [InputTouchBarID.preview]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == InputTouchBarID.preview else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = previewLabel
        return item
    }
}
