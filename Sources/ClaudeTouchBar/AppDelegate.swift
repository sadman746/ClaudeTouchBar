import AppKit
import Carbon.HIToolbox

private enum ID {
    static let tray = NSTouchBarItem.Identifier("com.claudetouchbar.app.tray")
    static let chatButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.chatButton")
    static let screenshotButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.screenshotButton")
    static let dictationButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.dictationButton")
    static let statusLabel = NSTouchBarItem.Identifier("com.claudetouchbar.app.statusLabel")
    static let resultLabel = NSTouchBarItem.Identifier("com.claudetouchbar.app.resultLabel")
    static let copyResultButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.copyResultButton")
    static let continueChatButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.continueChatButton")
    static let continueScreenshotButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.continueScreenshotButton")
    static let multiShotCountLabel = NSTouchBarItem.Identifier("com.claudetouchbar.app.multiShotCountLabel")
    static let addShotButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.addShotButton")
    static let writeCaptionButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.writeCaptionButton")
    static let sendMultiShotButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.sendMultiShotButton")
    static let stopButton = NSTouchBarItem.Identifier("com.claudetouchbar.app.stopButton")
    static let ambientLabel = NSTouchBarItem.Identifier("com.claudetouchbar.app.ambientLabel")
}

private enum Mode {
    case menu
    case loading
    case result(String)
    case error(String)
    case multiShot(count: Int)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSTextFieldDelegate {

    private var trayItem: NSCustomTouchBarItem!
    private var expandedTouchBar: NSTouchBar!
    private var hotkeys: GlobalHotkeys!
    private var mode: Mode = .menu {
        didSet { rebuildExpandedItems() }
    }

    // Guards every entry point that kicks off a new ClaudeRunner/screenshot
    // call. Nothing previously stopped the global hotkeys (which work no
    // matter what's on screen) from firing again while a request was already
    // in flight — e.g. ⌥Space during "Thinking…" could start a second
    // `claude -p --resume <sameSessionID>` racing the first one.
    private var isBusy: Bool {
        if case .loading = mode { return true }
        return false
    }

    // Every time we (re-)present our modal, push this out — the periodic
    // re-registration below skips itself until then, so the tray icon doesn't
    // pop back in over an actively-open menu/result screen. There's no way to
    // detect the system's own close ("X") button, so recovery after that is
    // still poll-based, just not while we know a session is legitimately open.
    private var trayReregistrationSuppressedUntil: Date?

    // Screenshots collected in the multi-shot flow, waiting to be sent together
    // with an optional caption. Files live in the same .touchbar-cache folder
    // as a single screenshot and are removed once sent (or discarded when a
    // new multi-shot session starts).
    private var multiShotURLs: [URL] = []

    // Set right before opening the text-input window for a multi-shot caption,
    // so submitText() knows to route the typed text into finishMultiShot(caption:)
    // instead of a plain chat message.
    private var pendingCaptionForMultiShot = false

    // The request currently running, so the Stop button shown while loading
    // can kill it instead of leaving the user stuck for up to 45s.
    private var currentRequest: ClaudeRequest?

    // Loading/streaming/error text. Was 220pt — well under half of the Touch
    // Bar, so text crawled through a narrow slot while most of the bar sat empty.
    private lazy var marquee = MarqueeLabel(frame: NSRect(x: 0, y: 0, width: 560, height: 30))

    // Finished answers scroll on their own as a ticker (pages that swapped
    // the text in place were tried and dropped); a long press copies, which
    // freed the space of a dedicated copy button.
    private lazy var resultMarquee: MarqueeLabel = {
        let label = MarqueeLabel(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        label.onLongPress = { [weak self] in self?.copyResultTapped() }
        return label
    }()

    // Idle screen: next event + unread mail, so opening the bar is useful
    // even before asking anything.
    private let agenda = AgendaCache()
    private lazy var ambientLabel = MarqueeLabel(frame: NSRect(x: 0, y: 0, width: 460, height: 30))

    // Frontmost app/window captured when the chat opens, sent with the question.
    private var pendingContext: FrontmostContext?

    // A long press on 💬 starts dictation; the release that follows must not
    // also count as a plain tap on the same button.
    private var swallowNextChatTap = false

    private lazy var inputWindow: InputWindow = {
        let window = InputWindow()
        window.textField.delegate = self
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        TouchBarPrivate.setShowsCloseBoxWhenNotFrontmost(true)
        ScreenshotCapture.purgeStaleCache()

        let button = trayButton()
        trayItem = NSCustomTouchBarItem(identifier: ID.tray)
        trayItem.view = button
        registerTrayItem()

        expandedTouchBar = NSTouchBar()
        expandedTouchBar.delegate = self
        rebuildExpandedItems()

        ambientLabel.text = agenda.summary
        agenda.onChange = { [weak self] summary in self?.ambientLabel.text = summary }
        agenda.start()

        // Presenting the modal touch bar drops our Control Strip registration, and
        // there's no callback for the system-provided close ("X") button, so we
        // can't re-assert on demand — poll instead, cheap and idempotent.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let until = self.trayReregistrationSuppressedUntil, until > Date() { return }
            // While typing, the icon stays out so the preview gets the width.
            if self.inputWindow.isKeyWindow { return }
            self.registerTrayItem()
        }

        hotkeys = GlobalHotkeys()
        hotkeys.register(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in
            self?.startTextInput(thenStartDictation: false)
        }
        // The hotkey is the "right now" path: one screenshot, sent straight
        // away. Collecting several shots stays available from the 📸 button.
        hotkeys.register(keyCode: kVK_Space, modifiers: optionKey | shiftKey) { [weak self] in
            self?.startQuickShot()
        }
    }

    private func registerTrayItem() {
        TouchBarPrivate.addSystemTrayItem(trayItem)
        TouchBarPrivate.setControlStripPresence(for: ID.tray, present: true)
    }

    /// Opening the chat from the tray icon goes through the modal, which drops
    /// the icon as a side effect and leaves the whole bar to the typing
    /// preview. The hotkey skips the modal, so do the same thing explicitly.
    private func hideTrayItem() {
        TouchBarPrivate.setControlStripPresence(for: ID.tray, present: false)
        TouchBarPrivate.removeSystemTrayItem(trayItem)
    }

    private func presentModal() {
        // Long enough to cover a full menu → loading (up to ClaudeRunner's 45s
        // timeout) → result cycle without the tray icon popping back mid-session;
        // handle(_:) below pushes it out again once the result actually arrives.
        trayReregistrationSuppressedUntil = Date().addingTimeInterval(60)
        TouchBarPrivate.presentModal(expandedTouchBar, trayIdentifier: ID.tray)
    }

    // Claude's brand orange (#d97757) — used to tint system icons so they read
    // as "Claude" without reproducing Anthropic's actual trademarked logo mark.
    private static let claudeOrange = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    /// A plain `NSButton(image:...)` with no bezel/frame overrides — that's what
    /// actually renders on the Touch Bar; adding a manual bezelStyle or frame
    /// here made icons invisible in earlier testing, so don't reintroduce either.
    /// Color comes from the SF Symbol's own palette configuration, not
    /// `contentTintColor` + isTemplate (that combination rendered invisible).
    private func symbolButton(_ symbolName: String, target: AnyObject, action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(paletteColors: [Self.claudeOrange])
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let image = base?.withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: target, action: action)
        return button
    }

    /// Uses the real Claude icon when bundled (local-only, gitignored — see
    /// README) so it never ships in the published repo; falls back to the same
    /// SF Symbol everyone else gets when the asset isn't there.
    private func trayButton() -> NSButton {
        if let path = Bundle.main.path(forResource: "claude-icon", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 22, height: 22)
            return NSButton(image: image, target: self, action: #selector(trayTapped))
        }
        return symbolButton("bubble.left.and.text.bubble.right.fill", target: self, action: #selector(trayTapped))
    }

    @objc private func trayTapped() {
        mode = .menu
        presentModal()
        agenda.refresh()
    }

    @objc private func chatTapped() {
        if swallowNextChatTap { swallowNextChatTap = false; return }
        startTextInput(thenStartDictation: false)
    }

    @objc private func chatLongPressed(_ press: NSPressGestureRecognizer) {
        switch press.state {
        case .began:
            swallowNextChatTap = true
            dictationTapped()
        case .ended, .cancelled, .failed:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.swallowNextChatTap = false
            }
        default:
            break
        }
    }

    @objc private func dictationTapped() {
        startTextInput(thenStartDictation: true)
    }

    @objc private func screenshotTapped() {
        startMultiShotFlow()
    }

    /// Flashes the shared marquee label instead of touching `mode`/rebuilding
    /// items — mirrors the multi-shot count update above, since the result
    /// screen's identifiers don't change and NSTouchBar won't re-invoke
    /// makeItemForIdentifier(_:) on its own.
    @objc private func copyResultTapped() {
        guard case .result(let answer) = mode else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(answer, forType: .string)

        resultMarquee.flash("Copiato ✓")
    }

    /// A real text field in a real key window is what makes macOS route real
    /// keystrokes to it — the private "system modal touch bar" API used for the
    /// menu/result screens does not support keyboard input for third-party apps.
    /// `InputWindow.makeTouchBar()` then shows a live preview of what's typed.
    private func startTextInput(thenStartDictation: Bool, forMultiShotCaption: Bool = false) {
        guard !isBusy else { return }
        // Re-pressing the same hotkey while the window is already open and
        // mid-typing used to silently wipe out whatever was typed so far,
        // since everything below reset the field unconditionally on every
        // call. Only reset when we're actually opening it fresh.
        let alreadyOpenForSamePurpose = inputWindow.isKeyWindow && pendingCaptionForMultiShot == forMultiShotCaption
        pendingCaptionForMultiShot = forMultiShotCaption

        if !alreadyOpenForSamePurpose {
            // Captured before NSApp.activate below makes this app frontmost.
            pendingContext = forMultiShotCaption ? nil : FrontmostContext.capture()
            inputWindow.contextHint = pendingContext?.hint
            TouchBarPrivate.dismissModal(expandedTouchBar)
            hideTrayItem()
            inputWindow.textField.stringValue = ""
            inputWindow.updatePreview("")
            NSApp.activate(ignoringOtherApps: true)
            inputWindow.makeKeyAndOrderFront(nil)
            inputWindow.makeFirstResponder(inputWindow.textField)
        }

        guard thenStartDictation else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.sendAction(NSSelectorFromString("startDictation:"), to: nil, from: nil)
        }
    }

    private func submitText() {
        let text = inputWindow.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        inputWindow.orderOut(nil)
        // Closing this window hands Touch Bar focus back to the system, which
        // silently drops our Control Strip registration just like presentModal
        // does — re-register right away instead of waiting on the 3s poll
        // (which can also be suppressed for up to 60s by a recent presentModal/
        // handle() call, making the icon's return feel random).
        registerTrayItem()

        if pendingCaptionForMultiShot {
            pendingCaptionForMultiShot = false
            finishMultiShot(caption: text)
            return
        }

        guard !text.isEmpty else { return }

        // A typed command instead of a Touch Bar button: there's no space left
        // for a dedicated "new conversation" icon among the others.
        if text.caseInsensitiveCompare("/new") == .orderedSame {
            ClaudeRunner.startNewSession()
            handle(.success("Nuova conversazione iniziata"))
            // handle(_:) only updates `mode`/the bar's item identifiers — unlike
            // the normal ask() path, nothing else in this branch calls
            // presentModal(), and the input window we just closed had taken
            // the modal off screen. Without this, the confirmation is built
            // but never actually shown: the Touch Bar (and the Control Strip
            // icon, suppressed for a bit by handle()) go blank.
            presentModal()
            return
        }

        guard !isBusy else { return }
        let question = pendingContext?.wrap(text) ?? text
        pendingContext = nil
        startLoading()
        currentRequest = ClaudeRunner.ask(question, onProgress: { [weak self] in self?.showProgress($0) }) { [weak self] result in
            self?.handle(result)
        }
    }

    private func startLoading() {
        // Streamed text grows from the right, like live typing; the finished
        // answer goes back to a normal ticker in handle(_:).
        marquee.followsTail = true
        mode = .loading
        // Coming from .error, ID.statusLabel is reused and makeItemForIdentifier(_:)
        // isn't called again — push the text directly, like handle(_:) does.
        marquee.text = "Thinking…"
        presentModal()
    }

    private func showProgress(_ progress: ClaudeProgress) {
        guard case .loading = mode else { return }
        switch progress {
        case .text(let text): marquee.text = text
        case .tool(let status): marquee.text = status
        }
    }

    @objc private func stopTapped() {
        currentRequest?.cancel()
    }

    // MARK: - Multi-shot screenshot flow

    private func startMultiShotFlow() {
        guard !isBusy else { return }
        resetMultiShot()
        captureAdditionalShot()
    }

    private func startQuickShot() {
        guard !isBusy else { return }
        resetMultiShot()
        captureAdditionalShot(sendImmediately: true)
    }

    private func resetMultiShot() {
        for url in multiShotURLs {
            try? FileManager.default.removeItem(at: url)
        }
        multiShotURLs.removeAll()
    }

    private func captureAdditionalShot(sendImmediately: Bool = false) {
        guard !isBusy else { return }
        startLoading()
        ScreenshotCapture.captureScreen { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.multiShotURLs.append(url)
                if sendImmediately {
                    self.sendShots(caption: "")
                    return
                }
                self.marquee.followsTail = false
                self.mode = .multiShot(count: self.multiShotURLs.count)
                // The item identifiers for .multiShot don't change between one
                // capture and the next, so NSTouchBar won't re-invoke
                // makeItemForIdentifier(_:) to pick up the new count on its own —
                // push the updated text into the shared label directly.
                self.marquee.text = "\(self.multiShotURLs.count) screenshot"
                self.presentModal()
            case .failure:
                let text = "Screenshot failed (Screen Recording permission required)"
                self.marquee.followsTail = false
                self.mode = .error(text)
                // Same ID.statusLabel reuse issue as in handle(_:) — push directly.
                self.marquee.text = text
            }
        }
    }

    @objc private func addShotTapped() {
        captureAdditionalShot()
    }

    @objc private func writeCaptionTapped() {
        startTextInput(thenStartDictation: false, forMultiShotCaption: true)
    }

    @objc private func sendMultiShotTapped() {
        finishMultiShot(caption: "")
    }

    private func finishMultiShot(caption: String) {
        guard !isBusy, !multiShotURLs.isEmpty else { return }
        sendShots(caption: caption)
    }

    /// No isBusy guard: the quick-shot path calls this while still in
    /// .loading from the capture itself.
    private func sendShots(caption: String) {
        let paths = multiShotURLs.map { $0.path }
        let urlsToClean = multiShotURLs
        multiShotURLs = []

        startLoading()
        currentRequest = ClaudeRunner.describeMultiple(imagePaths: paths, caption: caption, onProgress: { [weak self] in self?.showProgress($0) }) { [weak self] result in
            for url in urlsToClean { try? FileManager.default.removeItem(at: url) }
            self?.handle(result)
        }
    }

    private func handle(_ result: Result<String, ClaudeRunnerError>) {
        currentRequest = nil
        marquee.followsTail = false
        if case .failure(.cancelled) = result {
            mode = .menu
            trayReregistrationSuppressedUntil = Date().addingTimeInterval(10)
            return
        }
        // Roughly how long the text takes to scroll past once, so the tray icon
        // comes back soon after a short answer is closed with the system "X"
        // instead of always staying hidden for a full minute.
        let shown: String
        switch result {
        case .success(let answer): shown = answer
        case .failure(let error): shown = message(for: error)
        }
        trayReregistrationSuppressedUntil = Date().addingTimeInterval(min(60, 8 + Double(shown.count) * 0.15))
        switch result {
        case .success(let answer):
            mode = .result(answer)
            // Normally redundant — makeItemForIdentifier(_:) already sets it —
            // but a result following a result reuses ID.resultLabel.
            resultMarquee.text = answer
        case .failure(let error):
            let text = message(for: error)
            mode = .error(text)
            // .error reuses ID.statusLabel from .loading ("Thinking…"), and
            // NSTouchBar does NOT re-invoke makeItemForIdentifier(_:) for an
            // identifier that was already present before this mode change — so
            // without this direct push, any failure (timeout, non-zero exit,
            // empty response, ...) left the Touch Bar stuck showing "Thinking…"
            // forever even though the app itself had already moved on.
            marquee.text = text
        }
    }

    private func message(for error: ClaudeRunnerError) -> String {
        switch error {
        case .executableNotFound: return "claude CLI not found"
        case .timedOut: return "Timed out waiting for a response"
        case .cancelled: return "Stopped"
        case .nonZeroExit(let detail): return "Error: \(detail)"
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
            // Same reasoning as in submitText(): closing the window via Esc
            // also drops the Control Strip registration, so re-register now.
            registerTrayItem()
            if pendingCaptionForMultiShot {
                // Cancelling the caption shouldn't lose screenshots already
                // captured — go back to the multi-shot menu instead of leaving
                // nothing on screen.
                pendingCaptionForMultiShot = false
                mode = .multiShot(count: multiShotURLs.count)
                presentModal()
            }
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

    /// Every case starts with `.flexibleSpace`, which soaks up all the bar's
    /// remaining width before the real content. That anchors everything
    /// flush to the right edge, at the same spot, across every mode — both
    /// fixing the earlier left/right jump between screens of different
    /// width, and matching where the tray icon that opens this bar itself
    /// sits (far right, next to the system icons). `.fixedSpaceSmall`
    /// between items matches the breathing room Apple's own Touch Bar
    /// groups use.
    private func rebuildExpandedItems() {
        switch mode {
        // Dictation has no button of its own any more: long-press 💬.
        case .menu:
            expandedTouchBar.defaultItemIdentifiers = [
                .flexibleSpace,
                ID.ambientLabel, .fixedSpaceSmall, ID.chatButton, .fixedSpaceSmall, ID.screenshotButton
            ]
        case .loading:
            expandedTouchBar.defaultItemIdentifiers = [.flexibleSpace, ID.statusLabel, .fixedSpaceSmall, ID.stopButton]
        // Answer/error screens keep a single follow-up button: copy is a long
        // press on the text, and a new screenshot is always one ⇧⌥Space away — three
        // wide buttons were eating half the bar.
        case .result:
            expandedTouchBar.defaultItemIdentifiers = [
                .flexibleSpace, ID.resultLabel, .fixedSpaceSmall, ID.continueChatButton
            ]
        case .error:
            expandedTouchBar.defaultItemIdentifiers = [
                .flexibleSpace, ID.statusLabel, .fixedSpaceSmall, ID.continueChatButton
            ]
        case .multiShot:
            expandedTouchBar.defaultItemIdentifiers = [
                .flexibleSpace,
                ID.multiShotCountLabel, .fixedSpaceSmall, ID.addShotButton, .fixedSpaceSmall,
                ID.writeCaptionButton, .fixedSpaceSmall, ID.sendMultiShotButton
            ]
        }
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case ID.chatButton, ID.continueChatButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = symbolButton("text.bubble.fill", target: self, action: #selector(chatTapped))
            let press = NSPressGestureRecognizer(target: self, action: #selector(chatLongPressed(_:)))
            press.allowedTouchTypes = [.direct]
            press.minimumPressDuration = 0.5
            button.addGestureRecognizer(press)
            item.view = button
            return item

        case ID.ambientLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = ambientLabel
            return item

        case ID.screenshotButton, ID.continueScreenshotButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = symbolButton("camera.fill", target: self, action: #selector(screenshotTapped))
            return item

        case ID.copyResultButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = symbolButton("doc.on.doc.fill", target: self, action: #selector(copyResultTapped))
            return item

        case ID.dictationButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = symbolButton("mic.fill", target: self, action: #selector(dictationTapped))
            return item

        case ID.addShotButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = symbolButton("camera.fill", target: self, action: #selector(addShotTapped))
            return item

        case ID.writeCaptionButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = symbolButton("square.and.pencil", target: self, action: #selector(writeCaptionTapped))
            return item

        case ID.stopButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = symbolButton("stop.fill", target: self, action: #selector(stopTapped))
            return item

        case ID.sendMultiShotButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = symbolButton("paperplane.fill", target: self, action: #selector(sendMultiShotTapped))
            return item

        case ID.multiShotCountLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            if case .multiShot(let count) = mode {
                marquee.text = "\(count) screenshot"
            }
            item.view = marquee
            return item

        case ID.statusLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            switch mode {
            case .loading: marquee.text = "Thinking…"
            case .error(let message): marquee.text = message
            default: marquee.text = ""
            }
            item.view = marquee
            return item

        case ID.resultLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            if case .result(let answer) = mode { resultMarquee.text = answer }
            item.view = resultMarquee
            return item

        default:
            return nil
        }
    }
}
