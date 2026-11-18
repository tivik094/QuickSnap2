import Cocoa

// MARK: - Полноэкранный оверлей выбора области
final class RegionSelectionWindow: NSWindow {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.isReleasedWhenClosed = false
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false

        let view = SelectionCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { [weak self] localRect in
            guard let self = self else { return }
            let screenRect = CGRect(
                x: screen.frame.origin.x + localRect.origin.x,
                y: screen.frame.origin.y + localRect.origin.y,
                width: localRect.width,
                height: localRect.height
            )
            self.orderOut(nil)
            self.onRegionSelected?(screenRect)
        }
        view.onCancel = { [weak self] in
            self?.orderOut(nil)
            self?.onCancelled?()
        }
        self.contentView = view
        self.makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionCanvasView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let p1 = startPoint, let p2 = currentPoint else { return }
        let rect = NSRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )
        onComplete?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()

        guard let p1 = startPoint, let p2 = currentPoint else { return }
        let rect = NSRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )

        NSGraphicsContext.current?.compositingOperation = .clear
        rect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.systemGreen.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2.0
        border.stroke()

        let badgeText = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = badgeText.size(withAttributes: attrs)
        let badgeRect = NSRect(x: rect.minX, y: max(8, rect.minY - size.height - 10), width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
        badgeText.draw(at: NSPoint(x: badgeRect.minX + 7, y: badgeRect.minY + 3), withAttributes: attrs)
    }
}
