import Cocoa

// MARK: - Popover в чистом стиле iScreen Shoter (сетка 3x2 + прокрутка недавних снимков)
class MenuPopoverViewController: NSViewController {
    var onClosePopover: (() -> Void)?
    private var recentURLs: [URL] = []

    override func loadView() {
        let width: CGFloat = 312
        let height: CGFloat = 342
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.material = .menu
        root.blendingMode = .behindWindow
        root.state = .active

        // Верхняя панель: заголовок и общая шестерёнка настроек
        let titleLabel = makeLabel("QuickSnap", size: 13, weight: .medium, color: .labelColor)
        titleLabel.frame = NSRect(x: 16, y: height - 30, width: 140, height: 18)
        root.addSubview(titleLabel)

        let settingsBtn = PillButton(
            frame: NSRect(x: width - 44, y: height - 34, width: 28, height: 26),
            title: nil,
            symbolName: "gearshape",
            cornerRadius: 7
        ) { [weak self] in
            self?.onClosePopover?()
            SettingsWindowController.shared.show(tab: .general)
        }
        settingsBtn.toolTip = "Настройки"
        root.addSubview(settingsBtn)

        // 3 яркие круглые кнопки в ряд: Область, Окно, Видео
        let colW: CGFloat = (width - 24) / 3 // 96.0 pt
        let actionsY: CGFloat = height - 122

        let areaAction = makeCircleAction(
            frame: NSRect(x: 12, y: actionsY, width: colW, height: 82),
            icon: "viewfinder",
            circleColor: NSColor(calibratedRed: 0.85, green: 0.93, blue: 0.16, alpha: 1.0),
            iconColor: NSColor(calibratedWhite: 0.10, alpha: 1.0),
            title: "Область",
            shortcut: Config.areaShortcut.displayString
        ) { [weak self] in
            self?.onClosePopover?()
            ScreenCaptureManager.shared.capture(windowMode: false)
        }

        let winAction = makeCircleAction(
            frame: NSRect(x: 12 + colW, y: actionsY, width: colW, height: 82),
            icon: "macwindow",
            circleColor: NSColor(calibratedRed: 0.22, green: 0.88, blue: 0.96, alpha: 1.0),
            iconColor: NSColor(calibratedWhite: 0.10, alpha: 1.0),
            title: "Окно",
            shortcut: Config.windowShortcut.displayString
        ) { [weak self] in
            self?.onClosePopover?()
            ScreenCaptureManager.shared.capture(windowMode: true)
        }

        let videoX = 12 + colW * 2
        let videoAction = makeCircleAction(
            frame: NSRect(x: videoX, y: actionsY, width: colW, height: 82),
            icon: "video.fill",
            circleColor: NSColor(calibratedRed: 0.36, green: 0.92, blue: 0.62, alpha: 1.0),
            iconColor: NSColor(calibratedWhite: 0.10, alpha: 1.0),
            title: "Видео",
            shortcut: "\(Config.videoShortcut.displayString) • \(Config.videoFPS)fps"
        ) { [weak self] in
            self?.onClosePopover?()
            if #available(macOS 13.0, *) {
                ScreenRecorderManager.shared.toggleRecordingFlow()
            }
        }

        root.addSubview(areaAction)
        root.addSubview(winAction)
        root.addSubview(videoAction)

        // Разделитель
        let topSep = NSBox(frame: NSRect(x: 16, y: actionsY - 8, width: width - 32, height: 1))
        topSep.boxType = .separator
        root.addSubview(topSep)

        // Заголовок секции недавних снимков
        let recentHeader = makeLabel("Недавние снимки", size: 11, weight: .regular, color: .secondaryLabelColor)
        recentHeader.frame = NSRect(x: 16, y: actionsY - 30, width: 150, height: 15)
        root.addSubview(recentHeader)

        // Прокручиваемая область для 6 недавних снимков (сетка 3 колонки × 2 ряда)
        self.recentURLs = ScreenshotWatcher.shared.recentScreenshots(limit: 6)
        let scrollTopY: CGFloat = actionsY - 36
        let scrollBottomY: CGFloat = 50
        let scrollHeight: CGFloat = scrollTopY - scrollBottomY
        let scrollWidth: CGFloat = width - 32

        if recentURLs.isEmpty {
            let emptyLabel = makeLabel("Сделай снимок — он появится здесь", size: 11, weight: .regular, color: .tertiaryLabelColor)
            emptyLabel.frame = NSRect(x: 16, y: scrollBottomY + scrollHeight / 2 - 8, width: scrollWidth, height: 16)
            root.addSubview(emptyLabel)
        } else {
            let scrollView = NSScrollView(frame: NSRect(x: 16, y: scrollBottomY, width: scrollWidth, height: scrollHeight))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false

            let cols = 3
            let spacing: CGFloat = 8
            let thumbW: CGFloat = (scrollWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols) // 88.0 pt ровно
            let thumbH: CGFloat = 62
            let rows = Int(ceil(Double(recentURLs.count) / Double(cols)))
            let docHeight = max(scrollHeight, CGFloat(rows) * thumbH + CGFloat(max(0, rows - 1)) * spacing)

            let docView = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: scrollWidth, height: docHeight))

            for (idx, url) in recentURLs.enumerated() {
                let col = idx % cols
                let row = idx / cols
                let tx = CGFloat(col) * (thumbW + spacing)
                let ty = CGFloat(row) * (thumbH + spacing)

                let thumbBtn = NSButton(frame: NSRect(x: tx, y: ty, width: thumbW, height: thumbH))
                thumbBtn.isBordered = false
                thumbBtn.wantsLayer = true
                thumbBtn.layer?.cornerRadius = 7
                thumbBtn.layer?.masksToBounds = true
                thumbBtn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
                thumbBtn.layer?.borderWidth = 1
                thumbBtn.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
                thumbBtn.image = NSImage(contentsOf: url)
                thumbBtn.imageScaling = .scaleProportionallyUpOrDown
                thumbBtn.toolTip = url.lastPathComponent
                thumbBtn.tag = idx
                thumbBtn.target = self
                thumbBtn.action = #selector(openRecent(_:))
                docView.addSubview(thumbBtn)
            }

            scrollView.documentView = docView
            root.addSubview(scrollView)
        }

        // Нижняя компактная панель: папка слева и выход справа
        let folderBtn = PillButton(
            frame: NSRect(x: 16, y: 12, width: 34, height: 30),
            title: nil,
            symbolName: "folder",
            cornerRadius: 8
        ) { [weak self] in
            self?.onClosePopover?()
            NSWorkspace.shared.open(Config.saveDirectory)
        }
        folderBtn.toolTip = "Открыть папку: \(Config.saveDirectory.path)"

        let quitBtn = PillButton(
            frame: NSRect(x: width - 50, y: 12, width: 34, height: 30),
            title: nil,
            symbolName: "power",
            isDestructive: true,
            cornerRadius: 8
        ) {
            NSApp.terminate(nil)
        }
        quitBtn.toolTip = "Закрыть QuickSnap"

        root.addSubview(folderBtn)
        root.addSubview(quitBtn)
        self.view = root
    }

    private func makeCircleAction(frame: NSRect, icon: String, circleColor: NSColor, iconColor: NSColor, title: String, shortcut: String, action: @escaping () -> Void) -> NSView {
        let container = HoverCircleContainer(frame: frame, action: action)

        let circleSize: CGFloat = 40
        let circle = NSView(frame: NSRect(x: (frame.width - circleSize) / 2, y: frame.height - circleSize - 2, width: circleSize, height: circleSize))
        circle.wantsLayer = true
        circle.layer?.cornerRadius = circleSize / 2
        circle.layer?.backgroundColor = circleColor.cgColor
        container.circleView = circle

        let iv = NSImageView(frame: NSRect(x: (circleSize - 20) / 2, y: (circleSize - 20) / 2, width: 20, height: 20))
        if let sym = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            iv.contentTintColor = iconColor
        }
        circle.addSubview(iv)
        container.addSubview(circle)

        let tLabel = makeLabel(title, size: 12, weight: .regular, color: .labelColor)
        tLabel.alignment = .center
        tLabel.frame = NSRect(x: 2, y: 18, width: frame.width - 4, height: 16)
        container.addSubview(tLabel)

        let sLabel = makeLabel(shortcut, size: 10.5, weight: .regular, color: NSColor.white.withAlphaComponent(0.6))
        sLabel.alignment = .center
        sLabel.frame = NSRect(x: 2, y: 2, width: frame.width - 4, height: 14)
        container.addSubview(sLabel)

        return container
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    @objc private func openRecent(_ sender: NSButton) {
        guard sender.tag < recentURLs.count else { return }
        let url = recentURLs[sender.tag]
        onClosePopover?()
        ScreenshotWatcher.shared.openEditor(for: url)
    }
}

private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

private class HoverCircleContainer: NSView {
    weak var circleView: NSView?
    private let actionBlock: () -> Void
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, action: @escaping () -> Void) {
        self.actionBlock = action
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            circleView?.animator().alphaValue = 0.82
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            circleView?.animator().alphaValue = 1.0
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            actionBlock()
        }
    }
}
