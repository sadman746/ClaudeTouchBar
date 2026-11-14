import AppKit

/// Scrolls text horizontally when it doesn't fit the narrow width of a Touch Bar item.
final class MarqueeLabel: NSView {

    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var resumeWorkItem: DispatchWorkItem?
    private var panStartX: CGFloat = 0
    private var lastTick = Date()

    // Points per second. Time-based rather than a fixed step per tick, so a
    // late timer fire doesn't make the text visibly stutter.
    private let scrollSpeed: CGFloat = 45
    private let inset: CGFloat = 8

    /// Fired once when a finger rests on the text (used to copy an answer).
    var onLongPress: (() -> Void)?

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            followsTail ? showTail() : reset()
        }
    }

    /// When true, text that overflows is pinned so its END stays visible and
    /// nothing auto-scrolls — for live input and streamed answers, where the
    /// newest characters are the ones that matter. Restarting the scroll from
    /// the beginning on every keystroke/token (the old behavior) meant the end
    /// of a long sentence was never visible while it was being written.
    var followsTail = false {
        didSet {
            guard followsTail != oldValue else { return }
            followsTail ? showTail() : reset()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        // `lineBreakMode` alone does not stop wrapping — without these, a long
        // string can still lay out as two lines, and since this view's height is
        // fixed, the second line gets clipped to an illegible sliver. Force a
        // single line explicitly instead.
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.usesSingleLineMode = true
        addSubview(label)

        // Drag the text with a finger to re-read a part you missed, instead of
        // waiting for the whole ticker loop to come around again.
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [.direct]
        addGestureRecognizer(pan)

        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.allowedTouchTypes = [.direct]
        press.minimumPressDuration = 0.5
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var laidOutSize: NSSize = .zero

    override func layout() {
        super.layout()
        // The Touch Bar re-runs layout on its own (e.g. while the label moves);
        // restarting the ticker on each of those passes kept it pinned at the
        // start of the text forever. Only a real size change needs a redo.
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        followsTail ? showTail() : reset()
    }

    private var overflows: Bool {
        bounds.width > 0 && label.frame.width > bounds.width - 2 * inset
    }

    private func sizeLabel() {
        label.stringValue = text
        label.sizeToFit()
        var frame = label.frame
        frame.origin.y = (bounds.height - frame.height) / 2
        label.frame = frame
    }

    private func stopMotion() {
        timer?.invalidate()
        timer = nil
        resumeWorkItem?.cancel()
        resumeWorkItem = nil
    }

    private func showTail() {
        stopMotion()
        sizeLabel()
        label.frame.origin.x = overflows ? bounds.width - inset - label.frame.width : inset
    }

    private func reset() {
        stopMotion()
        sizeLabel()
        label.frame.origin.x = inset
        guard overflows else { return }
        // Give the reader a moment on the start of the text before it starts
        // moving — jumping straight into a scroll on every mode change (e.g.
        // "Thinking…" appearing) hurts readability more than it helps.
        scheduleScroll(after: 1.0)
    }

    /// Briefly replaces the text with a short message ("Copiato ✓"), then
    /// restarts the ticker from the beginning.
    func flash(_ message: String) {
        stopMotion()
        label.stringValue = message
        label.sizeToFit()
        label.frame.origin = CGPoint(x: inset, y: (bounds.height - label.frame.height) / 2)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.followsTail ? self.showTail() : self.reset()
        }
        resumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func scheduleScroll(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.startScrolling() }
        resumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func startScrolling() {
        timer?.invalidate()
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let now = Date()
        let elapsed = CGFloat(now.timeIntervalSince(lastTick))
        lastTick = now
        var frame = label.frame
        frame.origin.x -= scrollSpeed * elapsed
        if frame.origin.x + frame.width < 0 {
            frame.origin.x = bounds.width
        }
        label.frame = frame
    }

    @objc private func handlePan(_ pan: NSPanGestureRecognizer) {
        guard overflows else { return }
        switch pan.state {
        case .began:
            stopMotion()
            panStartX = label.frame.origin.x
        case .changed:
            let minX = bounds.width - inset - label.frame.width
            let x = panStartX + pan.translation(in: self).x
            label.frame.origin.x = min(inset, max(minX, x))
        case .ended, .cancelled:
            // Live text stays where the finger left it; a finished answer
            // resumes its ticker after a pause so it doesn't stall forever.
            if !followsTail { scheduleScroll(after: 2.0) }
        default:
            break
        }
    }

    @objc private func handlePress(_ press: NSPressGestureRecognizer) {
        if press.state == .began { onLongPress?() }
    }

    deinit { timer?.invalidate() }
}
