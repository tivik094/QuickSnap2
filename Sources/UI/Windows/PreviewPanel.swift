import Cocoa

// MARK: - Плавающая карточка предпросмотра с анимацией
final class PreviewPanel: NSPanel {
    private var dismissTimer: Timer?
    private let fileURL: URL
    private let image: NSImage
    private var targetFrame: NSRect = .zero
    private var isClosing = false
    private var trackingArea: NSTrackingArea?
    var onEditRequested: ((NSImage, URL) -> Void)?

    init(image: NSImage, fileURL: URL, pixelSize: CGSize) {
        self.image = image
        self.fileURL = fileURL

        let panelWidth: CGFloat = 348
        let panelHeight: CGFloat = 250
        let margin: CGFloat = 24

        let mouseLoc = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        let screenFrame = activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        self.targetFrame = NSRect(
            x: screenFrame.maxX - panelWidth - margin,
            y: screenFrame.minY + margin,
            width: panelWidth,
            height: panelHeight
        )

        let startFrame = NSRect(
            x: targetFrame.origin.x,
            y: targetFrame.origin.y - 30,
            width: panelWidth,
            height: panelHeight
        )

        super.init(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.alphaValue = 0.0
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setupUI(width: panelWidth, height: panelHeight, pixelSize: pixelSize)
        startDismissTimer()
    }

    deinit {
        dismissTimer?.invalidate()
    }

    private func setupUI(width: CGFloat, height: CGFloat, pixelSize: CGSize) {
        let shadowPadding: CGFloat = 10
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        rootView.wantsLayer = true

        let cardFrame = NSRect(
            x: shadowPadding,
            y: shadowPadding,
            width: width - shadowPadding * 2,
            height: height - shadowPadding * 2
        )

        let shadowWrapper = NSView(frame: cardFrame)
        shadowWrapper.wantsLayer = true
        shadowWrapper.layer?.shadowColor = NSColor.black.cgColor
        shadowWrapper.layer?.shadowOpacity = 0.45
        shadowWrapper.layer?.shadowOffset = NSSize(width: 0, height: -6)
        shadowWrapper.layer?.shadowRadius = 12

        // Правило внутреннего и внешнего: R_внутр (10) + Padding (12) = R_внеш (22)
        let pad: CGFloat = 12
        let innerRadius: CGFloat = 10
        let outerRadius: CGFloat = innerRadius + pad

        let container = NSVisualEffectView(frame: shadowWrapper.bounds)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = outerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let cw = container.bounds.width
        let ch = container.bounds.height
        let btnH: CGFloat = 30
        let metaH: CGFloat = 18

        // Чистое превью без перекрывающих плашек поверх картинки
        let imgY = pad + btnH + 8 + metaH + 6
        let imgBg = NSView(frame: NSRect(x: pad, y: imgY, width: cw - pad * 2, height: ch - imgY - pad))
        imgBg.wantsLayer = true
        imgBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        imgBg.layer?.cornerRadius = innerRadius
        imgBg.layer?.masksToBounds = true
        imgBg.layer?.borderWidth = 0.5
        imgBg.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let imageView = NSImageView(frame: imgBg.bounds.insetBy(dx: 4, dy: 4))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imgBg.addSubview(imageView)
        container.addSubview(imgBg)

        // Строка метаданных (разрешение и имя файла) под картинкой, не закрывая сам снимок
        let metaY = pad + btnH + 8
        let resLabel = NSTextField(labelWithString: "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
        resLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        resLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        resLabel.frame = NSRect(x: pad + 2, y: metaY, width: 130, height: metaH)
        container.addSubview(resLabel)

        let nameLabel = NSTextField(labelWithString: fileURL.lastPathComponent)
        nameLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        nameLabel.alignment = .right
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = NSRect(x: pad + 132, y: metaY, width: cw - pad * 2 - 134, height: metaH)
        container.addSubview(nameLabel)

        // Ряд кнопок с равными внешними отступами (12pt снизу, слева и справа) и радиусом 10pt
        let btnY: CGFloat = pad

        let editBtn = PillButton(
            frame: NSRect(x: pad, y: btnY, width: 100, height: btnH),
            title: "Разметка",
            symbolName: "pencil.tip.crop.circle",
            isAccent: true,
            cornerRadius: innerRadius
        ) { [weak self] in
            guard let self = self else { return }
            let img = self.image
            let url = self.fileURL
            self.animateOut()
            self.onEditRequested?(img, url)
        }
        editBtn.toolTip = "Открыть редактор разметки"

        let copyBtn = PillButton(
            frame: NSRect(x: pad + 106, y: btnY, width: 80, height: btnH),
            title: "Копия",
            symbolName: "doc.on.doc",
            cornerRadius: innerRadius
        ) { [weak self] in
            self?.copyAndClose()
        }
        copyBtn.toolTip = "Скопировать в буфер обмена"

        let finderBtn = PillButton(
            frame: NSRect(x: pad + 192, y: btnY, width: 32, height: btnH),
            title: nil,
            symbolName: "folder",
            cornerRadius: innerRadius
        ) { [weak self] in
            self?.revealInFinder()
        }
        finderBtn.toolTip = "Показать файл в Finder"

        let trashBtn = PillButton(
            frame: NSRect(x: cw - pad - 66, y: btnY, width: 30, height: btnH),
            title: nil,
            symbolName: "trash",
            isDestructive: true,
            cornerRadius: innerRadius
        ) { [weak self] in
            self?.deleteScreenshot()
        }
        trashBtn.toolTip = "Удалить скриншот"

        let closeBtn = PillButton(
            frame: NSRect(x: cw - pad - 30, y: btnY, width: 30, height: btnH),
            title: nil,
            symbolName: "xmark",
            cornerRadius: innerRadius
        ) { [weak self] in
            self?.animateOut()
        }
        closeBtn.toolTip = "Закрыть предпросмотр"

        container.addSubview(editBtn)
        container.addSubview(copyBtn)
        container.addSubview(finderBtn)
        container.addSubview(trashBtn)
        container.addSubview(closeBtn)

        shadowWrapper.addSubview(container)
        rootView.addSubview(shadowWrapper)
        self.contentView = rootView

        let area = NSTrackingArea(rect: rootView.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        rootView.addTrackingArea(area)
    }

    func animateIn() {
        self.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            self.animator().setFrame(targetFrame, display: true)
            self.animator().alphaValue = 1.0
        }
    }

    func animateOut() {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()
        dismissTimer = nil

        let exitFrame = NSRect(
            x: targetFrame.origin.x + 40,
            y: targetFrame.origin.y,
            width: targetFrame.width,
            height: targetFrame.height
        )

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().setFrame(exitFrame, display: true)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    override func mouseEntered(with event: NSEvent) {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    override func mouseExited(with event: NSEvent) {
        startDismissTimer()
    }

    private func startDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            self?.animateOut()
        }
    }

    private func copyAndClose() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        NSSound(named: "Tink")?.play()
        showCopiedToast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.animateOut()
        }
    }

    private func showCopiedToast() {
        guard let target = self.contentView?.subviews.first?.subviews.first else { return }
        let toastW: CGFloat = 136
        let toastH: CGFloat = 30
        let toast = NSView(frame: NSRect(
            x: floor((target.bounds.width - toastW) / 2),
            y: floor((target.bounds.height - toastH) / 2) + 14,
            width: toastW,
            height: toastH
        ))
        let bg = NSView(frame: toast.bounds)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 15
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        toast.addSubview(bg)

        let iv = NSImageView(frame: NSRect(x: 12, y: 8, width: 14, height: 14))
        if let sym = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) {
            iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            iv.contentTintColor = .systemGreen
        }
        toast.addSubview(iv)

        let lbl = NSTextField(labelWithString: "Скопировано")
        lbl.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        lbl.textColor = .white
        lbl.frame = NSRect(x: 31, y: 6, width: 96, height: 18)
        toast.addSubview(lbl)

        toast.alphaValue = 0
        target.addSubview(toast)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            toast.animator().alphaValue = 1.0
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        animateOut()
    }

    private func deleteScreenshot() {
        try? FileManager.default.removeItem(at: fileURL)
        NSSound(named: "Funk")?.play()
        animateOut()
    }
}
