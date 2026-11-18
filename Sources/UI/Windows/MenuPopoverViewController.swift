import Cocoa
import ImageIO

// MARK: - Popover: Нативный macOS (по умолчанию) + Стекло (Glass) + Классика
final class MenuPopoverViewController: NSViewController {
    var onClosePopover: (() -> Void)?
    private var recentURLs: [URL] = []
    private var thumbnailCache: [URL: NSImage] = [:]
    private var thumbnailButtons: [NSButton] = []
    private var themeObserver: NSObjectProtocol?

    deinit {
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 316, height: 348))
        root.appearance = NSAppearance(named: .darkAqua)
        self.view = root
        rebuildUI()

        themeObserver = NotificationCenter.default.addObserver(
            forName: .quickSnapThemeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildUI()
        }
    }

    private func rebuildUI() {
        guard let root = self.view as? NSVisualEffectView else { return }
        root.subviews.forEach { $0.removeFromSuperview() }
        root.layer?.sublayers?.removeAll(where: { $0.name == "GlassHighlightLayer" })
        thumbnailButtons.removeAll()

        let tokens = Config.tokens
        let width: CGFloat = 316
        let height: CGFloat = 348

        root.wantsLayer = true
        root.layer?.cornerRadius = 13
        root.layer?.masksToBounds = true

        if tokens.useBlurMaterial {
            root.material = tokens.popoverMaterial
            root.blendingMode = .behindWindow
            root.state = .active
            root.layer?.backgroundColor = tokens.tintOverlayColor
            root.layer?.borderWidth = 1.0
            root.layer?.borderColor = tokens.windowBorderColor

            if tokens.isGlass {
                let grad = CAGradientLayer()
                grad.name = "GlassHighlightLayer"
                grad.frame = root.bounds
                grad.colors = [
                    NSColor.white.withAlphaComponent(0.18).cgColor,
                    NSColor.white.withAlphaComponent(0.03).cgColor,
                    NSColor.clear.cgColor
                ]
                grad.locations = [0.0, 0.35, 1.0]
                grad.startPoint = CGPoint(x: 0.5, y: 1.0)
                grad.endPoint = CGPoint(x: 0.5, y: 0.0)
                root.layer?.insertSublayer(grad, at: 0)
            }
        } else {
            root.state = .inactive
            let blackBg = NSView(frame: root.bounds)
            blackBg.wantsLayer = true
            blackBg.layer?.backgroundColor = tokens.solidBackgroundColor.cgColor
            blackBg.layer?.cornerRadius = 13
            blackBg.layer?.borderWidth = 1.0
            blackBg.layer?.borderColor = tokens.windowBorderColor
            root.addSubview(blackBg)
        }

        // Верхняя панель: заголовок и шестерёнка
        let titleLabel = NSTextField.makeLabel("QuickSnap", size: 13.5, weight: .semibold, color: .white)
        titleLabel.frame = NSRect(x: 16, y: height - 31, width: 140, height: 19)
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

        // 3 кнопки действий (ровная целочисленная сетка 92 pt)
        let gap: CGFloat = tokens.isClassic ? 0 : 8
        let totalInnerW: CGFloat = width - 24
        let colW: CGFloat = floor((totalInnerW - gap * 2) / 3)
        let actionsY: CGFloat = height - 122

        let areaAction = makeActionItem(
            frame: NSRect(x: 12, y: actionsY, width: colW, height: 82),
            icon: "viewfinder",
            accentColor: tokens.areaAccent,
            title: "Область",
            shortcut: Config.areaShortcut.displayString,
            tokens: tokens
        ) { [weak self] in
            self?.onClosePopover?()
            ScreenCaptureManager.shared.capture(windowMode: false)
        }

        let winAction = makeActionItem(
            frame: NSRect(x: floor(12 + colW + gap), y: actionsY, width: colW, height: 82),
            icon: "macwindow",
            accentColor: tokens.windowAccent,
            title: "Окно",
            shortcut: Config.windowShortcut.displayString,
            tokens: tokens
        ) { [weak self] in
            self?.onClosePopover?()
            ScreenCaptureManager.shared.capture(windowMode: true)
        }

        let videoShortcutText = tokens.showFpsInVideoShortcut
            ? "\(Config.videoShortcut.displayString) • \(Config.videoFPS)fps"
            : Config.videoShortcut.displayString

        let videoAction = makeActionItem(
            frame: NSRect(x: floor(12 + (colW + gap) * 2), y: actionsY, width: colW, height: 82),
            icon: "video.fill",
            accentColor: tokens.videoAccent,
            title: "Видео",
            shortcut: videoShortcutText,
            tokens: tokens
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
        let recentHeader = NSTextField.makeLabel("Недавние снимки", size: 11.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.6))
        recentHeader.frame = NSRect(x: 16, y: actionsY - 30, width: 160, height: 16)
        root.addSubview(recentHeader)

        // Прокручиваемая сетка до 18 недавних снимков
        self.recentURLs = ScreenshotWatcher.shared.recentScreenshots(limit: 18)
        let scrollTopY: CGFloat = actionsY - 36
        let scrollBottomY: CGFloat = 52
        let scrollHeight: CGFloat = scrollTopY - scrollBottomY
        let scrollWidth: CGFloat = width - 32

        if recentURLs.isEmpty {
            let emptyLabel = NSTextField.makeLabel("Сделай снимок — он появится здесь", size: 11.5, weight: .regular, color: NSColor.white.withAlphaComponent(0.45))
            emptyLabel.frame = NSRect(x: 16, y: scrollBottomY + scrollHeight / 2 - 8, width: scrollWidth, height: 16)
            root.addSubview(emptyLabel)
        } else {
            let scrollView = NSScrollView(frame: NSRect(x: 16, y: scrollBottomY, width: scrollWidth, height: scrollHeight))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false

            let cols = 3
            let spacing: CGFloat = 8
            let thumbW: CGFloat = floor((scrollWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols))
            let thumbH: CGFloat = 62
            let rows = Int(ceil(Double(recentURLs.count) / Double(cols)))
            let docHeight = max(scrollHeight + 1, CGFloat(rows) * thumbH + CGFloat(max(0, rows - 1)) * spacing + 4)

            let docView = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: scrollWidth, height: docHeight))

            for (idx, url) in recentURLs.enumerated() {
                let col = idx % cols
                let row = idx / cols
                let tx = CGFloat(col) * (thumbW + spacing)
                let ty = CGFloat(row) * (thumbH + spacing)

                let thumbBtn = ThumbnailTileButton(
                    frame: NSRect(x: tx, y: ty, width: thumbW, height: thumbH),
                    tokens: tokens,
                    url: url,
                    onDelete: { [weak self] in
                        self?.thumbnailCache.removeValue(forKey: url)
                        self?.rebuildUI()
                    }
                ) { [weak self] in
                    self?.onClosePopover?()
                    ScreenshotWatcher.shared.openEditor(for: url)
                }
                thumbBtn.toolTip = url.lastPathComponent
                docView.addSubview(thumbBtn)
                thumbnailButtons.append(thumbBtn)
            }

            scrollView.documentView = docView
            root.addSubview(scrollView)
            loadThumbnailsAsync(maxPixelSize: Int(max(thumbW, thumbH) * 2))
        }

        // Нижняя панель: чистый горизонтальный разделитель без вложенных рамок
        let bottomSep = NSView(frame: NSRect(x: 0, y: 46, width: width, height: 1))
        bottomSep.wantsLayer = true
        bottomSep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        root.addSubview(bottomSep)

        let folderBtn = PillButton(
            frame: NSRect(x: 14, y: 9, width: 84, height: 28),
            title: "Снимки",
            symbolName: "folder",
            cornerRadius: 8
        ) { [weak self] in
            guard let self = self else { return }
            let latest = self.recentURLs.first
            let targetDir = Config.saveDirectory
            self.onClosePopover?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if let latestFile = latest, FileManager.default.fileExists(atPath: latestFile.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([latestFile])
                } else {
                    NSWorkspace.shared.open(targetDir)
                }
            }
        }
        folderBtn.toolTip = "Открыть папку: \(Config.saveDirectory.path)"
        root.addSubview(folderBtn)

        if PinnedScreenshotWindow.allOpen.count > 0 {
            let closeAllBtn = PillButton(
                frame: NSRect(x: 104, y: 9, width: 112, height: 28),
                title: "Закрыть стикеры",
                symbolName: "xmark.circle",
                cornerRadius: 8
            ) {
                PinnedScreenshotWindow.closeAll()
            }
            closeAllBtn.toolTip = "Закрыть все закреплённые стикеры"
            root.addSubview(closeAllBtn)
        }

        if tokens.showPowerButtonInFooter {
            let quitBtn = PillButton(
                frame: NSRect(x: width - 46, y: 9, width: 32, height: 28),
                title: nil,
                symbolName: "power",
                isDestructive: true,
                cornerRadius: 8
            ) {
                NSApp.terminate(nil)
            }
            quitBtn.toolTip = "Закрыть QuickSnap"
            root.addSubview(quitBtn)
        }
    }

    private func loadThumbnailsAsync(maxPixelSize: Int) {
        let urls = recentURLs
        let validSet = Set(urls)
        thumbnailCache = thumbnailCache.filter { validSet.contains($0.key) }

        let buttons = thumbnailButtons
        let existingCache = thumbnailCache

        for (idx, url) in urls.enumerated() where idx < buttons.count {
            if let cached = existingCache[url] {
                buttons[idx].image = cached
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (idx, url) in urls.enumerated() where idx < buttons.count {
                if existingCache[url] != nil { continue }
                guard let thumb = Self.downsampledThumbnail(at: url, maxPixelSize: maxPixelSize) else { continue }
                let btn = buttons[idx]
                DispatchQueue.main.async {
                    guard btn.superview != nil else { return }
                    self?.thumbnailCache[url] = thumb
                    btn.image = thumb
                }
            }
        }
    }

    private static func downsampledThumbnail(at url: URL, maxPixelSize: Int) -> NSImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }

    private func makeActionItem(
        frame: NSRect,
        icon: String,
        accentColor: NSColor,
        title: String,
        shortcut: String,
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> NSView {
        let container = HoverActionContainer(frame: frame, tokens: tokens, action: action)

        if tokens.iconCircleBackground {
            let circleSize: CGFloat = 40
            let circle = NSView(frame: NSRect(x: floor((frame.width - circleSize) / 2), y: frame.height - circleSize - 2, width: circleSize, height: circleSize))
            circle.wantsLayer = true
            circle.layer?.cornerRadius = circleSize / 2
            circle.layer?.backgroundColor = accentColor.cgColor
            container.iconHolder = circle

            let iv = NSImageView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
            if let sym = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
                iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
                iv.contentTintColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)
            }
            circle.addSubview(iv)
            container.addSubview(circle)
        } else if tokens.isGlass {
            let iv = NSImageView(frame: NSRect(x: floor((frame.width - 24) / 2), y: frame.height - 36, width: 24, height: 24))
            iv.wantsLayer = true
            iv.layer?.shadowColor = accentColor.cgColor
            iv.layer?.shadowRadius = 7
            iv.layer?.shadowOpacity = 0.85
            iv.layer?.shadowOffset = .zero
            if let sym = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
                iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
                iv.contentTintColor = accentColor
            }
            container.addSubview(iv)
        } else {
            let badgeSize: CGFloat = 32
            let badge = NSView(frame: NSRect(x: floor((frame.width - badgeSize) / 2), y: frame.height - badgeSize - 6, width: badgeSize, height: badgeSize))
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 8
            badge.layer?.backgroundColor = accentColor.withAlphaComponent(0.16).cgColor
            container.addSubview(badge)

            let iv = NSImageView(frame: NSRect(x: 6, y: 6, width: 20, height: 20))
            if let sym = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
                iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
                iv.contentTintColor = accentColor
            }
            badge.addSubview(iv)
        }

        let tLabel = NSTextField.makeLabel(title, size: 12, weight: .medium, color: .white)
        tLabel.alignment = .center
        tLabel.frame = NSRect(x: 2, y: 20, width: frame.width - 4, height: 16)
        container.addSubview(tLabel)

        let keycapW = min(frame.width - 14, max(44, CGFloat(shortcut.count) * 7.5 + 14))
        let keycap = NSView(frame: NSRect(x: floor((frame.width - keycapW) / 2), y: 5, width: keycapW, height: 16))
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 4
        keycap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let sLabel = NSTextField.makeLabel(shortcut, size: 10.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.80))
        sLabel.alignment = .center
        sLabel.frame = NSRect(x: 0, y: 1, width: keycapW, height: 14)
        keycap.addSubview(sLabel)
        container.addSubview(keycap)

        return container
    }
}

private final class ThumbnailTileButton: NSButton {
    private let tokens: ThemeTokens
    private let onDelete: () -> Void
    private let onClick: () -> Void
    private let url: URL
    private let imageLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    override var image: NSImage? {
        didSet {
            if tokens.cropThumbnailsToFill {
                imageLayer.contents = image
            } else {
                super.image = image
            }
        }
    }

    init(frame: NSRect, tokens: ThemeTokens, url: URL, onDelete: @escaping () -> Void, onClick: @escaping () -> Void) {
        self.tokens = tokens
        self.url = url
        self.onDelete = onDelete
        self.onClick = onClick
        super.init(frame: frame)

        self.isBordered = false
        self.title = ""
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.masksToBounds = true
        self.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.white.withAlphaComponent(tokens.isGlass ? 0.26 : 0.18).cgColor

        if tokens.cropThumbnailsToFill {
            imageLayer.frame = bounds
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.masksToBounds = true
            self.layer?.addSublayer(imageLayer)
        } else {
            self.imageScaling = .scaleProportionallyUpOrDown
        }

        self.target = self
        self.action = #selector(handleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.borderColor = NSColor.white.withAlphaComponent(tokens.isGlass ? 0.26 : 0.18).cgColor
    }

    @objc private func handleTap() {
        onClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть в редакторе", action: #selector(openInEditor), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Закрепить поверх окон", action: #selector(pinScreenshot), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Удалить снимок", action: #selector(deleteScreenshot), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openInEditor() {
        onClick()
    }

    @objc private func pinScreenshot() {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        PinnedScreenshotManager.shared.pin(image: image)
    }

    @objc private func deleteScreenshot() {
        try? FileManager.default.removeItem(at: url)
        NSSound(named: "Funk")?.play()
        onDelete()
    }
}

private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

private final class HoverActionContainer: NSView {
    weak var iconHolder: NSView?
    private let tokens: ThemeTokens
    private let actionBlock: () -> Void
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, tokens: ThemeTokens, action: @escaping () -> Void) {
        self.tokens = tokens
        self.actionBlock = action
        super.init(frame: frame)

        if !tokens.isClassic {
            wantsLayer = true
            layer?.cornerRadius = 11
            layer?.backgroundColor = tokens.cardBackgroundColor
            layer?.borderWidth = 1.0
            layer?.borderColor = tokens.cardBorderColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if !tokens.isClassic {
            layer?.backgroundColor = tokens.cardHoverBackgroundColor
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                iconHolder?.animator().alphaValue = 0.82
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !tokens.isClassic {
            layer?.backgroundColor = tokens.cardBackgroundColor
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                iconHolder?.animator().alphaValue = 1.0
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            actionBlock()
        }
    }
}
