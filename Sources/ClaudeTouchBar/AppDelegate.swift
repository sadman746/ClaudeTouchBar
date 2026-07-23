import AppKit
import Carbon.HIToolbox

private enum ID {
    static let tray = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.tray")
    static let chatButton = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.chatButton")
    static let screenshotButton = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.screenshotButton")
    static let dictationButton = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.dictationButton")
    static let statusLabel = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.statusLabel")
    static let resultLabel = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.resultLabel")
    static let continueChatButton = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.continueChatButton")
    static let continueScreenshotButton = NSTouchBarItem.Identifier("com.sadman.claudetouchbar.continueScreenshotButton")
}

private enum Mode {
    case menu
    case loading
    case result(String)
    case error(String)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSTextFieldDelegate {

    private var trayItem: NSCustomTouchBarItem!
    private var expandedTouchBar: NSTouchBar!
    private var hotkeys: GlobalHotkeys!
    private var mode: Mode = .menu {
        didSet { rebuildExpandedItems() }
    }

    private lazy var marquee = MarqueeLabel(frame: NSRect(x: 0, y: 0, width: 220, height: 30))

    private lazy var inputWindow: InputWindow = {
        let window = InputWindow()
        window.textField.delegate = self
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        TouchBarPrivate.setShowsCloseBoxWhenNotFrontmost(true)

        let button = NSButton(title: "🤖", target: self, action: #selector(trayTapped))
        trayItem = NSCustomTouchBarItem(identifier: ID.tray)
        trayItem.view = button
        registerTrayItem()

        expandedTouchBar = NSTouchBar()
        expandedTouchBar.delegate = self
        rebuildExpandedItems()

        // Presenting the modal touch bar drops our Control Strip registration, and
        // there's no callback for the system-provided close ("X") button, so we
        // can't re-assert on demand — poll instead, cheap and idempotent.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.registerTrayItem()
        }

        hotkeys = GlobalHotkeys()
        hotkeys.register(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in
            self?.startTextInput(thenStartDictation: false)
        }
        hotkeys.register(keyCode: kVK_Space, modifiers: optionKey | shiftKey) { [weak self] in
            self?.runScreenshotFlow()
        }
    }

    private func registerTrayItem() {
        TouchBarPrivate.addSystemTrayItem(trayItem)
        TouchBarPrivate.setControlStripPresence(for: ID.tray, present: true)
    }

    @objc private func trayTapped() {
        mode = .menu
        TouchBarPrivate.presentModal(expandedTouchBar, trayIdentifier: ID.tray)
    }

    @objc private func chatTapped() {
        startTextInput(thenStartDictation: false)
    }

    @objc private func dictationTapped() {
        startTextInput(thenStartDictation: true)
    }

    @objc private func screenshotTapped() {
        runScreenshotFlow()
    }

    /// A real text field in a real key window is what makes macOS route real
    /// keystrokes to it — the private "system modal touch bar" API used for the
    /// menu/result screens does not support keyboard input for third-party apps.
    /// `InputWindow.makeTouchBar()` then shows a live preview of what's typed.
    private func startTextInput(thenStartDictation: Bool) {
        TouchBarPrivate.dismissModal(expandedTouchBar)
        inputWindow.textField.stringValue = ""
        inputWindow.updatePreview("")
        NSApp.activate(ignoringOtherApps: true)
        inputWindow.makeKeyAndOrderFront(nil)
        inputWindow.makeFirstResponder(inputWindow.textField)

        guard thenStartDictation else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.sendAction(NSSelectorFromString("startDictation:"), to: nil, from: nil)
        }
    }

    private func submitText() {
        let text = inputWindow.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        inputWindow.orderOut(nil)
        guard !text.isEmpty else { return }

        mode = .loading
        TouchBarPrivate.presentModal(expandedTouchBar, trayIdentifier: ID.tray)
        ClaudeRunner.ask(text) { [weak self] result in
            self?.handle(result)
        }
    }

    private func runScreenshotFlow() {
        mode = .loading
        TouchBarPrivate.presentModal(expandedTouchBar, trayIdentifier: ID.tray)
        ScreenshotCapture.captureScreen { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                ClaudeRunner.describe(imagePath: url.path) { [weak self] answerResult in
                    try? FileManager.default.removeItem(at: url)
                    self?.handle(answerResult)
                }
            case .failure:
                self.mode = .error("Screenshot non riuscito (serve permesso Registrazione Schermo)")
            }
        }
    }

    private func handle(_ result: Result<String, ClaudeRunnerError>) {
        switch result {
        case .success(let answer):
            mode = .result(answer)
        case .failure(let error):
            mode = .error(message(for: error))
        }
    }

    private func message(for error: ClaudeRunnerError) -> String {
        switch error {
        case .executableNotFound: return "claude CLI non trovato"
        case .timedOut: return "Timeout: nessuna risposta in tempo"
        case .nonZeroExit(let detail): return "Errore: \(detail)"
        }
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitText()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            inputWindow.orderOut(nil)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        inputWindow.updatePreview(inputWindow.textField.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        // Disable the system's own predictive-completion candidate bar so our
        // live text preview (via makeTouchBar()) isn't fought over/replaced.
        (inputWindow.textField.currentEditor() as? NSTextView)?.isAutomaticTextCompletionEnabled = false
    }

    // MARK: - NSTouchBarDelegate

    private func rebuildExpandedItems() {
        switch mode {
        case .menu:
            expandedTouchBar.defaultItemIdentifiers = [ID.chatButton, ID.screenshotButton, ID.dictationButton]
        case .loading:
            expandedTouchBar.defaultItemIdentifiers = [ID.statusLabel]
        case .result:
            expandedTouchBar.defaultItemIdentifiers = [ID.resultLabel, ID.continueChatButton, ID.continueScreenshotButton]
        case .error:
            expandedTouchBar.defaultItemIdentifiers = [ID.statusLabel, ID.continueChatButton, ID.continueScreenshotButton]
        }
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case ID.chatButton, ID.continueChatButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSButton(title: "💬", target: self, action: #selector(chatTapped))
            return item

        case ID.screenshotButton, ID.continueScreenshotButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSButton(title: "📸", target: self, action: #selector(screenshotTapped))
            return item

        case ID.dictationButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSButton(title: "🎤", target: self, action: #selector(dictationTapped))
            return item

        case ID.statusLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            switch mode {
            case .loading: marquee.text = "Sto pensando…"
            case .error(let message): marquee.text = message
            default: marquee.text = ""
            }
            item.view = marquee
            return item

        case ID.resultLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            if case .result(let answer) = mode { marquee.text = answer }
            item.view = marquee
            return item

        default:
            return nil
        }
    }
}
