import Cocoa

// MARK: - Невидимая для кликов рамка вокруг области записи экрана
final class RecordingBorderWindow: NSPanel {
    private let borderView: RecordingBorderView

    init(captureRect: CGRect) {
        let lineWidth: CGFloat = 2.0
        let pad: CGFloat = lineWidth + 1.0
        let windowFrame = captureRect.insetBy(dx: -pad, dy: -pad)

        self.borderView = RecordingBorderView(
            frame: NSRect(origin: .zero, size: windowFrame.size),
            inset: pad,
            lineWidth: lineWidth
        )

        super.init(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = borderView
    }

    func setPaused(_ paused: Bool) {
        borderView.isPaused = paused
    }
}

private final class RecordingBorderView: NSView {
    private let inset: CGFloat
    private let lineWidth: CGFloat

    var isPaused: Bool = false {
        didSet {
            if oldValue != isPaused {
                needsDisplay = true
            }
        }
    }

    init(frame: NSRect, inset: CGFloat, lineWidth: CGFloat) {
        self.inset = inset
        self.lineWidth = lineWidth
        super.init(frame: frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let targetRect = bounds.insetBy(dx: inset - lineWidth / 2, dy: inset - lineWidth / 2)
        let color = isPaused
            ? NSColor.systemYellow.withAlphaComponent(0.85)
            : NSColor.systemRed.withAlphaComponent(0.82)

        color.setStroke()
        let path = NSBezierPath(roundedRect: targetRect, xRadius: 3, yRadius: 3)
        path.lineWidth = lineWidth
        if isPaused {
            let pattern: [CGFloat] = [6.0, 4.0]
            path.setLineDash(pattern, count: pattern.count, phase: 0)
        }
        path.stroke()
    }
}
