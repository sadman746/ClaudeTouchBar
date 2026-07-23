import AppKit

/// Scrolls text horizontally when it doesn't fit the narrow width of a Touch Bar item.
final class MarqueeLabel: NSView {

    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    var text: String = "" {
        didSet { reset() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        reset()
    }

    private func reset() {
        timer?.invalidate()
        label.stringValue = text
        label.sizeToFit()

        var frame = label.frame
        frame.origin = CGPoint(x: 8, y: (bounds.height - frame.height) / 2)
        label.frame = frame

        guard label.frame.width > bounds.width - 16, bounds.width > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        var frame = label.frame
        frame.origin.x -= 1
        if frame.origin.x + frame.width < 0 {
            frame.origin.x = bounds.width
        }
        label.frame = frame
    }

    deinit { timer?.invalidate() }
}
