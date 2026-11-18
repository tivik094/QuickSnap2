import AppKit

final class PinnedScreenshotManager {
    static let shared = PinnedScreenshotManager()
    fileprivate(set) var windows: [PinnedScreenshotWindow] = []

    private init() {}

    var hasPinnedWindows: Bool { !windows.isEmpty }

    func pin(image: NSImage) {
        let win = PinnedScreenshotWindow(image: image)
        win.onClose = { [weak self, weak win] in
            guard let self = self, let win = win else { return }
            self.windows.removeAll { $0 === win }
        }
        windows.append(win)
        win.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSSound(named: "Tink")?.play()
    }

    func closeAll() {
        let copy = windows
        windows.removeAll()
        copy.forEach { $0.orderOut(nil) }
    }
}

final class PinnedScreenshotWindow: NSWindow, NSMenuDelegate {
    static var allOpen: [PinnedScreenshotWindow] { PinnedScreenshotManager.shared.windows }
    static func closeAll() { PinnedScreenshotManager.shared.closeAll() }

    var onClose: (() -> Void)?

    private let baseSize: NSSize
    private var currentScale: CGFloat = 1.0
    private var hintDismissWorkItem: DispatchWorkItem?
    private let imageView = NSImageView()
    private let closeButton = NSButton()
    private let copyButton = NSButton()
    private let hintPill = NSView()

    init(image: NSImage) {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        let screenFrame = activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var initialSize = image.size
        if initialSize.width <= 0 || initialSize.height <= 0 {
            initialSize = NSSize(width: 320, height: 240)
        }

        let maxW = screenFrame.width * 0.65
        let maxH = screenFrame.height * 0.65
        if initialSize.width > maxW || initialSize.height > maxH {
            let ratio = min(maxW / initialSize.width, maxH / initialSize.height)
            initialSize = NSSize(width: round(initialSize.width * ratio), height: round(initialSize.height * ratio))
        }
        self.baseSize = initialSize

        let originX = round(screenFrame.midX - initialSize.width / 2)
        let originY = round(screenFrame.midY - initialSize.height / 2)
        let contentRect = NSRect(x: originX, y: originY, width: initialSize.width, height: initialSize.height)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = PinnedContainerView(frame: NSRect(origin: .zero, size: initialSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor

        container.onScroll = { [weak self] event in
            self?.handleScroll(event)
        }
        container.onDoubleClick = { [weak self] in
            self?.closePin()
        }
        container.onHoverChanged = { [weak self] hovered in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self?.closeButton.animator().alphaValue = hovered ? 1.0 : 0.7
                self?.copyButton.animator().alphaValue = hovered ? 1.0 : 0.0
            }
        }
        let contextMenu = buildContextMenu()
        contextMenu.delegate = self
        container.menu = contextMenu

        imageView.frame = container.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)

        setupOverlayButton(
            closeButton,
            frame: NSRect(x: 8, y: initialSize.height - 32, width: 24, height: 24),
            symbol: "xmark",
            tooltip: "Закрыть (Esc или двойной клик)",
            action: #selector(closePin)
        )
        closeButton.autoresizingMask = [.minYMargin, .maxXMargin]
        closeButton.alphaValue = 0.7
        container.addSubview(closeButton)

        setupOverlayButton(
            copyButton,
            frame: NSRect(x: 38, y: initialSize.height - 32, width: 24, height: 24),
            symbol: "doc.on.doc",
            tooltip: "Скопировать (⌘C)",
            action: #selector(copyPinImage)
        )
        copyButton.autoresizingMask = [.minYMargin, .maxXMargin]
        copyButton.alphaValue = 0.0
        container.addSubview(copyButton)

        if initialSize.width >= 210 && initialSize.height >= 90 {
            let pillW = min(initialSize.width - 24, 270)
            hintPill.frame = NSRect(x: round((initialSize.width - pillW) / 2), y: 10, width: pillW, height: 24)
            hintPill.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
            hintPill.wantsLayer = true
            hintPill.layer?.cornerRadius = 12
            hintPill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor

            let hintLabel = NSTextField(labelWithString: "Двойной клик или Esc — закрыть")
            hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            hintLabel.textColor = .white
            hintLabel.alignment = .center
            hintLabel.frame = NSRect(x: 8, y: 4, width: pillW - 16, height: 15)
            hintPill.addSubview(hintLabel)
            container.addSubview(hintPill)

            let workItem = DispatchWorkItem { [weak self] in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.35
                    self?.hintPill.animator().alphaValue = 0.0
                }, completionHandler: { [weak self] in
                    self?.hintPill.removeFromSuperview()
                })
            }
            self.hintDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: workItem)
        }

        self.contentView = container
    }

    private func setupOverlayButton(_ btn: NSButton, frame: NSRect, symbol: String, tooltip: String, action: Selector) {
        btn.frame = frame
        btn.bezelStyle = .circular
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        btn.layer?.cornerRadius = frame.width / 2
        btn.layer?.borderWidth = 1
        btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
            btn.image = sym.withSymbolConfiguration(cfg)
            btn.contentTintColor = .white
        }
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Скопировать изображение", action: #selector(copyPinImage), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let resetItem = NSMenuItem(title: "Исходный размер (100%)", action: #selector(resetScale), keyEquivalent: "0")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Закрыть стикер", action: #selector(closePin), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        let closeAllItem = NSMenuItem(title: "Закрыть все стикеры", action: #selector(closeAllPins), keyEquivalent: "")
        closeAllItem.target = self
        closeAllItem.tag = 999
        menu.addItem(closeAllItem)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let hasMultiple = PinnedScreenshotManager.shared.windows.count > 1
        menu.item(withTag: 999)?.isHidden = !hasMultiple
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {
            closePin()
        } else if event.keyCode == 8 && flags == .command {
            copyPinImage()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func copyPinImage() {
        guard let img = imageView.image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        NSSound(named: "Pop")?.play()
    }

    @objc private func resetScale() {
        currentScale = 1.0
        self.alphaValue = 1.0
        let oldFrame = self.frame
        let newOrigin = NSPoint(
            x: round(oldFrame.midX - baseSize.width / 2),
            y: round(oldFrame.midY - baseSize.height / 2)
        )
        self.setFrame(NSRect(origin: newOrigin, size: baseSize), display: true, animate: true)
    }

    private func handleScroll(_ event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.1 else { return }

        if event.modifierFlags.contains(.option) {
            let step: CGFloat = event.hasPreciseScrollingDeltas ? delta * 0.004 : delta * 0.03
            self.alphaValue = min(1.0, max(0.25, self.alphaValue + step))
            return
        }

        let factor: CGFloat = event.hasPreciseScrollingDeltas ? (1.0 + delta * 0.004) : (delta > 0 ? 1.06 : 0.94)
        let minScale = max(0.3, max(72.0 / baseSize.width, 44.0 / baseSize.height))
        let newScale = min(2.5, max(minScale, currentScale * factor))
        guard abs(newScale - currentScale) > 0.002 else { return }
        currentScale = newScale

        let newW = round(baseSize.width * currentScale)
        let newH = round(baseSize.height * currentScale)
        let oldFrame = self.frame
        let newOrigin = NSPoint(
            x: round(oldFrame.midX - newW / 2),
            y: round(oldFrame.midY - newH / 2)
        )
        self.setFrame(NSRect(origin: newOrigin, size: NSSize(width: newW, height: newH)), display: true)
    }

    @objc private func closePin() {
        hintDismissWorkItem?.cancel()
        hintDismissWorkItem = nil
        self.orderOut(nil)
        onClose?()
    }

    @objc private func closeAllPins() {
        PinnedScreenshotManager.shared.closeAll()
    }
}

private final class PinnedContainerView: NSView {
    var onScroll: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseUp(with: event)
        }
    }
}
