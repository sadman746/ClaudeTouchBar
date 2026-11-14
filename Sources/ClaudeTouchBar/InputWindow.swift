import AppKit

private enum InputTouchBarID {
    static let preview = NSTouchBarItem.Identifier("com.claudetouchbar.app.preview")
}

/// The field editor is what actually gets keystrokes for an NSTextField (the
/// field itself is just a display proxy). Its default `makeTouchBar()` returns
/// the system's predictive-completion candidate bar, and — being the first
/// responder — that wins over InputWindow's own `makeTouchBar()` in the
/// responder chain lookup. Returning nil here lets the lookup fall through to
/// the window, which is what actually makes the live preview show up
/// reliably, for both typed and pasted text.
private final class SilentFieldEditor: NSTextView {
    override func makeTouchBar() -> NSTouchBar? { nil }
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
final class InputWindow: NSWindow, NSTouchBarDelegate, NSWindowDelegate {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    let textField: NSTextField
    // The preview is the only item on this bar, so it can take most of the
    // width; followsTail keeps the end of what's being typed in view.
    private let previewLabel: MarqueeLabel = {
        let label = MarqueeLabel(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        label.followsTail = true
        return label
    }()

    // Handed out via windowWillReturnFieldEditor(_:to:) below so the field
    // editor that actually owns keyboard/paste input is ours, not AppKit's
    // default (which shadows our Touch Bar preview — see SilentFieldEditor).
    private lazy var fieldEditor: NSTextView = {
        let editor = SilentFieldEditor()
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.isAutomaticTextCompletionEnabled = false
        return editor
    }()

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
        // Present on every Space: otherwise activating the app jumps back to
        // whichever desktop the window was last shown on.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // Not alpha 0 / off-screen: a truly invisible or off-screen window may
        // not be treated as a real interactive surface by WindowServer.
        // Transparent background + no shadow removes the visible flash while
        // the window remains "real" at the very top screen edge.
        setFrameOrigin(NSPoint(x: 0, y: NSScreen.main?.frame.height ?? 0))
        contentView?.addSubview(field)
        delegate = self
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        fieldEditor
    }

    /// What the question will be about (frontmost app/window), shown in the
    /// empty placeholder so it's clear the context travels with it.
    var contextHint: String?

    func updatePreview(_ text: String) {
        if text.isEmpty {
            previewLabel.text = contextHint.map { "Chiedi su \($0)…" } ?? "Type your question…"
        } else {
            previewLabel.text = text + "▏"
        }
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
