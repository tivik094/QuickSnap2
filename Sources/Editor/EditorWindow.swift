import Cocoa
import CoreImage
import Vision

// MARK: - Встроенный быстрый редактор (Стрелки, Рамки, Блюр, Кадрирование)
enum AnnotationTool: Int {
    case arrow = 0
    case rectangle = 1
    case blur = 2
    case crop = 3
}

struct AnnotationItem {
    let tool: AnnotationTool
    let start: NSPoint
    let end: NSPoint
    let color: NSColor
    let lineWidth: CGFloat
}

private struct CanvasSnapshot {
    let image: NSImage
    let annotations: [AnnotationItem]
    let canvasSize: NSSize
}

final class EditorCanvasView: NSView {
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let annotationCornerRadius: CGFloat = 6.0

    private(set) var baseImage: NSImage
    var currentTool: AnnotationTool = .arrow
    var currentColor: NSColor = NSColor(calibratedRed: 0.96, green: 0.28, blue: 0.28, alpha: 1.0)
    var lineThickness: CGFloat = 3.5
    var annotations: [AnnotationItem] = []
    var onCropApplied: ((NSSize) -> Void)?

    private var undoStack: [CanvasSnapshot] = []
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var blurredImage: NSImage?

    // Живое кадрирование
    private var cropSelection: NSRect?
    private var cropStart: NSPoint?

    init(frame: NSRect, image: NSImage) {
        self.baseImage = image
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.cornerRadius = 10
        self.layer?.masksToBounds = true
        self.layer?.borderWidth = 1.0
        self.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        self.blurredImage = makePixelatedImage(from: image)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makePixelatedImage(from source: NSImage) -> NSImage? {
        var proposedRect = NSRect(origin: .zero, size: source.size)
        guard let cgSource = source.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgSource)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(18.0, forKey: kCIInputScaleKey)

        guard let output = filter.outputImage?.cropped(to: ciImage.extent),
              let cgImg = Self.sharedCIContext.createCGImage(output, from: ciImage.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImg, size: source.size)
    }

    func undo() {
        if !annotations.isEmpty {
            annotations.removeLast()
            needsDisplay = true
            return
        }
        if let prev = undoStack.popLast() {
            baseImage = prev.image
            annotations = prev.annotations
            blurredImage = makePixelatedImage(from: prev.image)
            onCropApplied?(prev.canvasSize)
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if currentTool == .crop {
            cropStart = convert(event.locationInWindow, from: nil)
            cropSelection = nil
        } else {
            dragStart = convert(event.locationInWindow, from: nil)
            dragCurrent = dragStart
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if currentTool == .crop, let start = cropStart {
            let cur = convert(event.locationInWindow, from: nil)
            cropSelection = NSRect(
                x: min(start.x, cur.x),
                y: min(start.y, cur.y),
                width: abs(cur.x - start.x),
                height: abs(cur.y - start.y)
            ).intersection(bounds)
        } else {
            dragCurrent = convert(event.locationInWindow, from: nil)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if currentTool == .crop {
            if let start = cropStart {
                let cur = convert(event.locationInWindow, from: nil)
                let rect = NSRect(
                    x: min(start.x, cur.x),
                    y: min(start.y, cur.y),
                    width: abs(cur.x - start.x),
                    height: abs(cur.y - start.y)
                ).intersection(bounds)
                cropSelection = nil
                cropStart = nil
                if rect.width > 12, rect.height > 12 {
                    applyLiveCrop(rect)
                }
            }
            cropStart = nil
            cropSelection = nil
            needsDisplay = true
            return
        }

        guard let s = dragStart, let e = dragCurrent else { return }
        if hypot(e.x - s.x, e.y - s.y) > 4 {
            annotations.append(AnnotationItem(tool: currentTool, start: s, end: e, color: currentColor, lineWidth: lineThickness))
        }
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
    }

    private func applyLiveCrop(_ crop: NSRect) {
        guard let currentRendered = renderFinalImage() else { return }
        var proposed = NSRect(origin: .zero, size: currentRendered.size)
        guard let fullCG = currentRendered.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }

        let sx = CGFloat(fullCG.width) / bounds.width
        let sy = CGFloat(fullCG.height) / bounds.height
        let cropPx = CGRect(
            x: round(crop.minX * sx),
            y: round((bounds.height - crop.maxY) * sy),
            width: round(crop.width * sx),
            height: round(crop.height * sy)
        ).intersection(CGRect(x: 0, y: 0, width: fullCG.width, height: fullCG.height))

        guard let croppedCG = fullCG.cropping(to: cropPx), croppedCG.width > 0, croppedCG.height > 0 else { return }

        undoStack.append(CanvasSnapshot(image: baseImage, annotations: annotations, canvasSize: bounds.size))

        let croppedRep = NSBitmapImageRep(cgImage: croppedCG)
        croppedRep.size = crop.size
        let newImage = NSImage(size: crop.size)
        newImage.addRepresentation(croppedRep)

        baseImage = newImage
        annotations.removeAll()
        blurredImage = makePixelatedImage(from: newImage)
        NSSound(named: "Tink")?.play()
        onCropApplied?(crop.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(in: bounds)
        for item in annotations {
            drawAnnotation(item)
        }
        if let s = dragStart, let e = dragCurrent {
            drawAnnotation(AnnotationItem(tool: currentTool, start: s, end: e, color: currentColor, lineWidth: lineThickness))
        }

        if let crop = cropSelection, crop.width > 2, crop.height > 2 {
            NSGraphicsContext.saveGraphicsState()
            let dimPath = NSBezierPath(rect: bounds)
            dimPath.append(NSBezierPath(rect: crop))
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dimPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            let border = NSBezierPath(roundedRect: crop, xRadius: 4, yRadius: 4)
            border.lineWidth = 2.0
            NSColor.white.withAlphaComponent(0.9).setStroke()
            border.stroke()

            let badge = "\(Int(crop.width)) × \(Int(crop.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let size = badge.size(withAttributes: attrs)
            let badgeRect = NSRect(x: crop.minX, y: max(8, crop.minY - size.height - 10), width: size.width + 12, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
            badge.draw(at: NSPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 3), withAttributes: attrs)
        }
    }

    private func drawAnnotation(_ item: AnnotationItem) {
        let radius = Self.annotationCornerRadius
        switch item.tool {
        case .crop:
            break
        case .rectangle:
            let rect = NSRect(
                x: min(item.start.x, item.end.x),
                y: min(item.start.y, item.end.y),
                width: abs(item.end.x - item.start.x),
                height: abs(item.end.y - item.start.y)
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = item.lineWidth
            item.color.setStroke()
            path.stroke()

        case .blur:
            let rect = NSRect(
                x: min(item.start.x, item.end.x),
                y: min(item.start.y, item.end.y),
                width: abs(item.end.x - item.start.x),
                height: abs(item.end.y - item.start.y)
            )
            if let blurred = blurredImage {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
                blurred.draw(in: bounds)
                NSGraphicsContext.restoreGraphicsState()
            }

        case .arrow:
            drawArrow(from: item.start, to: item.end, color: item.color, lineWidth: item.lineWidth)
        }
    }

    private func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor, lineWidth: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 14.0 + lineWidth * 1.4
        let arrowAngle: CGFloat = .pi / 6.5

        let lineEnd = NSPoint(
            x: end.x - (arrowLength * 0.7) * cos(angle),
            y: end.y - (arrowLength * 0.7) * sin(angle)
        )

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.move(to: start)
        path.line(to: lineEnd)
        color.setStroke()
        path.stroke()

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - arrowLength * cos(angle - arrowAngle), y: end.y - arrowLength * sin(angle - arrowAngle)))
        head.line(to: NSPoint(x: end.x - arrowLength * cos(angle + arrowAngle), y: end.y - arrowLength * sin(angle + arrowAngle)))
        head.close()
        color.setFill()
        head.fill()
    }

    func renderFinalImage() -> NSImage? {
        var proposedRect = NSRect(origin: .zero, size: baseImage.size)
        let targetPixelsW: Int
        let targetPixelsH: Int
        if let cgBase = baseImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            targetPixelsW = cgBase.width
            targetPixelsH = cgBase.height
        } else {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            targetPixelsW = Int(bounds.width * scale)
            targetPixelsH = Int(bounds.height * scale)
        }

        let targetColorSpace = window?.screen?.colorSpace ?? NSScreen.main?.colorSpace ?? .displayP3
        guard targetPixelsW > 0, targetPixelsH > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: targetPixelsW,
                pixelsHigh: targetPixelsH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              )?.retagging(with: targetColorSpace) else {
            return nil
        }
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        baseImage.draw(in: bounds)
        for item in annotations {
            drawAnnotation(item)
        }
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: bounds.size)
        result.addRepresentation(rep)
        return result
    }

    func extractTextOffline(completion: @escaping (Result<String, Error>) -> Void) {
        let sourceImage = renderFinalImage() ?? baseImage
        var proposed = NSRect(origin: .zero, size: sourceImage.size)
        guard let cgImage = sourceImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            completion(.success(""))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { req, error in
                if let error = error {
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let fullText = lines.joined(separator: "\n")
                DispatchQueue.main.async { completion(.success(fullText)) }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ru-RU", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

final class EditorWindow: NSWindow {
    private static let paletteColors: [(NSColor, String)] = [
        (NSColor(calibratedRed: 0.96, green: 0.28, blue: 0.28, alpha: 1.0), "Красный"),
        (NSColor(calibratedRed: 0.22, green: 0.62, blue: 1.00, alpha: 1.0), "Синий"),
        (NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.45, alpha: 1.0), "Зелёный"),
        (NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.15, alpha: 1.0), "Жёлтый"),
        (NSColor(calibratedWhite: 0.96, alpha: 1.0), "Белый")
    ]

    private let canvas: EditorCanvasView
    private let fileURL: URL
    private var toolButtons: [AnnotationTool: DockIconButton] = [:]
    private var colorSwatches: [DockColorSwatch] = []
    private var thicknessButtons: [DockDotButton] = []

    private let strokeGroup = NSStackView()
    private let hoverBadge = NSView()
    private let hoverLabel = NSTextField(labelWithString: "")

    // Внешний нижний отступ дока (22pt) > 2× внутреннего padding (7pt), чтобы тулбар парил над окном
    private let sidePad: CGFloat = 16
    private let dockBottomMargin: CGFloat = 22
    private let dockH: CGFloat = 46
    private let topHeaderH: CGFloat = 34

    init(image: NSImage, fileURL: URL) {
        self.fileURL = fileURL

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let maxW = screenFrame.width * 0.82
        let reservedV = dockH + dockBottomMargin + topHeaderH + 22
        let maxH = screenFrame.height * 0.84 - reservedV

        let origW = max(image.size.width, 1)
        let origH = max(image.size.height, 1)
        let ratio = min(maxW / origW, maxH / origH, 1.0)
        let canvasW = origW * ratio
        let canvasH = origH * ratio

        let winW = max(canvasW + sidePad * 2, 480)
        let winH = max(canvasH + reservedV, 240)
        let winSize = NSSize(width: winW, height: winH)
        let winOrigin = NSPoint(
            x: screenFrame.midX - winSize.width / 2,
            y: screenFrame.midY - winSize.height / 2
        )

        let canvasX = round((winW - canvasW) / 2)
        let canvasY = dockBottomMargin + dockH + 14
        self.canvas = EditorCanvasView(frame: NSRect(x: canvasX, y: canvasY, width: canvasW, height: canvasH), image: image)

        super.init(
            contentRect: NSRect(origin: winOrigin, size: winSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = ""
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.level = .normal
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.appearance = NSAppearance(named: .darkAqua)

        let glassBackground = NSVisualEffectView(frame: NSRect(origin: .zero, size: winSize))
        glassBackground.autoresizingMask = [.width, .height]
        glassBackground.material = .hudWindow
        glassBackground.blendingMode = .behindWindow
        glassBackground.state = .active
        self.contentView = glassBackground

        setupHeaderTitle(in: glassBackground)

        canvas.onCropApplied = { [weak self] newSize in
            self?.resizeForCanvas(newSize)
        }

        glassBackground.addSubview(canvas)
        setupToolbar()
        setupHoverBadge()
    }

    private func setupHeaderTitle(in root: NSView) {
        let headerLabel = NSTextField(labelWithString: "QuickSnap — Быстрая разметка")
        headerLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        headerLabel.textColor = NSColor.white.withAlphaComponent(0.84)
        headerLabel.alignment = .center
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            headerLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            headerLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8)
        ])
    }

    private func resizeForCanvas(_ newCanvasSize: NSSize) {
        let reservedV = dockH + dockBottomMargin + topHeaderH + 22
        let winW = max(newCanvasSize.width + sidePad * 2, 480)
        let winH = max(newCanvasSize.height + reservedV, 220)
        let oldFrame = self.frame
        let newOrigin = NSPoint(
            x: round(oldFrame.midX - winW / 2),
            y: round(oldFrame.midY - winH / 2)
        )
        self.setFrame(NSRect(origin: newOrigin, size: NSSize(width: winW, height: winH)), display: true, animate: true)
        canvas.frame = NSRect(
            x: round((winW - newCanvasSize.width) / 2),
            y: dockBottomMargin + dockH + 14,
            width: newCanvasSize.width,
            height: newCanvasSize.height
        )
    }

    private func setupHoverBadge() {
        guard let root = self.contentView else { return }
        hoverBadge.wantsLayer = true
        hoverBadge.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.94).cgColor
        hoverBadge.layer?.cornerRadius = 7
        hoverBadge.layer?.masksToBounds = true
        hoverBadge.layer?.borderWidth = 0.5
        hoverBadge.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        hoverBadge.alphaValue = 0.0
        hoverBadge.isHidden = true

        hoverLabel.textColor = .white
        hoverLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        hoverLabel.alignment = .center
        hoverLabel.translatesAutoresizingMaskIntoConstraints = false
        hoverBadge.addSubview(hoverLabel)
        NSLayoutConstraint.activate([
            hoverLabel.centerXAnchor.constraint(equalTo: hoverBadge.centerXAnchor),
            hoverLabel.centerYAnchor.constraint(equalTo: hoverBadge.centerYAnchor)
        ])

        root.addSubview(hoverBadge)
    }

    private func showHoverHint(_ text: String?, anchorView: NSView) {
        guard let root = self.contentView else { return }
        guard let text = text, !text.isEmpty else {
            hoverBadge.alphaValue = 0.0
            hoverBadge.isHidden = true
            return
        }
        hoverLabel.stringValue = text
        hoverLabel.sizeToFit()
        let badgeW = round(hoverLabel.frame.width + 18)
        let badgeH: CGFloat = 24
        let anchorFrame = anchorView.convert(anchorView.bounds, to: root)
        let x = max(sidePad, min(root.bounds.width - badgeW - sidePad, round(anchorFrame.midX - badgeW / 2)))
        let y = dockBottomMargin + dockH + 8
        hoverBadge.frame = NSRect(x: x, y: y, width: badgeW, height: badgeH)
        hoverBadge.isHidden = false
        hoverBadge.alphaValue = 1.0
    }

    private func setupToolbar() {
        guard let root = self.contentView else { return }

        // Глубокая тёмная стеклянная капсула с высоким контрастом (внутренний R = 8, padding = 7 -> внешний R = 15)
        let dockGlass = NSView()
        dockGlass.translatesAutoresizingMaskIntoConstraints = false
        dockGlass.wantsLayer = true
        dockGlass.layer?.cornerRadius = 15
        dockGlass.layer?.masksToBounds = true
        dockGlass.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.88).cgColor
        dockGlass.layer?.borderWidth = 1.0
        dockGlass.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let dock = NSStackView()
        dock.orientation = .horizontal
        dock.alignment = .centerY
        dock.spacing = 8
        dock.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        dock.translatesAutoresizingMaskIntoConstraints = false

        func makeSeparator() -> NSView {
            let sep = NSView()
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
            sep.heightAnchor.constraint(equalToConstant: 20).isActive = true
            return sep
        }

        // 1. Унифицированный сет иконок SF Symbols (15pt, Medium, зоны клика 32×32)
        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 4
        tools.alignment = .centerY

        let toolDefs: [(AnnotationTool, String, String)] = [
            (.arrow, "arrow.up.right", "Стрелка (1)"),
            (.rectangle, "rectangle", "Рамка (2)"),
            (.blur, "square.grid.3x3.fill", "Пикселизация (3)"),
            (.crop, "crop", "Обрезать (4)")
        ]
        for (tool, sym, tip) in toolDefs {
            let b = DockIconButton(symbolName: sym, tooltip: tip) { [weak self] in
                self?.updateToolSelection(tool)
            }
            b.onHover = { [weak self, weak b] hovered in
                guard let b = b else { return }
                self?.showHoverHint(hovered ? tip : nil, anchorView: b)
            }
            tools.addArrangedSubview(b)
            toolButtons[tool] = b
        }
        dock.addArrangedSubview(tools)
        dock.addArrangedSubview(makeSeparator())

        // 2. Чёткая градация толщины (4pt, 8pt, 12pt) + Палитра цветов
        strokeGroup.orientation = .horizontal
        strokeGroup.spacing = 8
        strokeGroup.alignment = .centerY

        let thickGroup = NSStackView()
        thickGroup.orientation = .horizontal
        thickGroup.spacing = 3
        thickGroup.alignment = .centerY
        let dotDefs: [(CGFloat, CGFloat, String)] = [
            (4.0, 2.0, "Тонкая линия"),
            (8.0, 3.5, "Средняя линия"),
            (12.0, 5.5, "Толстая линия")
        ]
        for (idx, (dotSize, lineVal, tip)) in dotDefs.enumerated() {
            let b = DockDotButton(dotDiameter: dotSize, tooltip: tip) { [weak self] in
                guard let self = self else { return }
                self.canvas.lineThickness = lineVal
                for tb in self.thicknessButtons { tb.isSelected = false }
                self.thicknessButtons[idx].isSelected = true
            }
            b.onHover = { [weak self, weak b] hovered in
                guard let b = b else { return }
                self?.showHoverHint(hovered ? tip : nil, anchorView: b)
            }
            thickGroup.addArrangedSubview(b)
            thicknessButtons.append(b)
        }
        thicknessButtons[1].isSelected = true
        canvas.lineThickness = 3.5
        strokeGroup.addArrangedSubview(thickGroup)

        let colors = NSStackView()
        colors.orientation = .horizontal
        colors.spacing = 2
        colors.alignment = .centerY
        for (idx, (color, colorName)) in Self.paletteColors.enumerated() {
            let swatch = DockColorSwatch(color: color, name: colorName, isSelected: idx == 0) { [weak self] in
                self?.selectColor(index: idx)
            }
            swatch.onHover = { [weak self, weak swatch] hovered in
                guard let swatch = swatch else { return }
                self?.showHoverHint(hovered ? colorName : nil, anchorView: swatch)
            }
            colorSwatches.append(swatch)
            colors.addArrangedSubview(swatch)
        }
        strokeGroup.addArrangedSubview(colors)
        strokeGroup.addArrangedSubview(makeSeparator())
        dock.addArrangedSubview(strokeGroup)

        // 3. Действия
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 5
        actions.alignment = .centerY

        let undoBtn = DockIconButton(symbolName: "arrow.uturn.backward", tooltip: "Отменить (⌘Z)") { [weak self] in
            self?.canvas.undo()
        }
        undoBtn.onHover = { [weak self, weak undoBtn] hovered in
            guard let undoBtn = undoBtn else { return }
            self?.showHoverHint(hovered ? "Отменить (⌘Z)" : nil, anchorView: undoBtn)
        }

        let ocrBtn = DockIconButton(symbolName: "text.viewfinder", tooltip: "Распознать текст (⌘T)") { [weak self] in
            self?.recognizeTextToClipboard()
        }
        ocrBtn.onHover = { [weak self, weak ocrBtn] hovered in
            guard let ocrBtn = ocrBtn else { return }
            self?.showHoverHint(hovered ? "Распознать текст (⌘T)" : nil, anchorView: ocrBtn)
        }

        let pinBtn = DockIconButton(symbolName: "pin.fill", tooltip: "Закрепить поверх окон") { [weak self] in
            self?.pinAndClose()
        }
        pinBtn.onHover = { [weak self, weak pinBtn] hovered in
            guard let pinBtn = pinBtn else { return }
            self?.showHoverHint(hovered ? "Закрепить стикером" : nil, anchorView: pinBtn)
        }

        let doneBtn = NSView()
        doneBtn.wantsLayer = true
        doneBtn.layer?.backgroundColor = NSColor(calibratedRed: 0.20, green: 0.50, blue: 0.89, alpha: 1.0).cgColor
        doneBtn.layer?.cornerRadius = 8
        doneBtn.layer?.borderWidth = 0.5
        doneBtn.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        doneBtn.toolTip = "Сохранить и скопировать (⌘C / Enter)"
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.widthAnchor.constraint(equalToConstant: 74).isActive = true
        doneBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let doneLabel = NSTextField(labelWithString: "Готово")
        doneLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        doneLabel.textColor = .white
        doneLabel.alignment = .center
        doneLabel.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.addSubview(doneLabel)
        NSLayoutConstraint.activate([
            doneLabel.centerXAnchor.constraint(equalTo: doneBtn.centerXAnchor),
            doneLabel.centerYAnchor.constraint(equalTo: doneBtn.centerYAnchor)
        ])
        doneBtn.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(saveAndCopy)))

        actions.addArrangedSubview(undoBtn)
        actions.addArrangedSubview(ocrBtn)
        actions.addArrangedSubview(pinBtn)
        actions.addArrangedSubview(doneBtn)
        dock.addArrangedSubview(actions)

        dockGlass.addSubview(dock)
        root.addSubview(dockGlass)

        NSLayoutConstraint.activate([
            dock.topAnchor.constraint(equalTo: dockGlass.topAnchor),
            dock.bottomAnchor.constraint(equalTo: dockGlass.bottomAnchor),
            dock.leadingAnchor.constraint(equalTo: dockGlass.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: dockGlass.trailingAnchor),

            dockGlass.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dockGlass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -dockBottomMargin),
            dockGlass.heightAnchor.constraint(equalToConstant: dockH)
        ])

        updateToolSelection(.arrow)
    }

    private func updateToolSelection(_ active: AnnotationTool) {
        canvas.currentTool = active
        for (tool, btn) in toolButtons {
            btn.isSelected = (tool == active)
        }
        let needsStrokeStyle = (active == .arrow || active == .rectangle)
        strokeGroup.isHidden = !needsStrokeStyle
    }

    private func selectColor(index: Int) {
        guard index >= 0, index < Self.paletteColors.count else { return }
        canvas.currentColor = Self.paletteColors[index].0
        for (idx, swatch) in colorSwatches.enumerated() {
            swatch.isSelected = (idx == index)
        }
    }

    private func showStatusBanner(_ message: String) {
        guard let root = self.contentView else { return }
        hoverLabel.stringValue = message
        hoverLabel.sizeToFit()
        let badgeW = round(hoverLabel.frame.width + 20)
        let badgeH: CGFloat = 26
        let x = round((root.bounds.width - badgeW) / 2)
        let y = dockBottomMargin + dockH + 10
        hoverBadge.frame = NSRect(x: x, y: y, width: badgeW, height: badgeH)
        hoverBadge.isHidden = false
        hoverBadge.alphaValue = 1.0

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self = self, self.hoverLabel.stringValue == message else { return }
            self.hoverBadge.alphaValue = 0.0
            self.hoverBadge.isHidden = true
        }
    }

    @objc private func recognizeTextToClipboard() {
        showStatusBanner("Распознаю текст…")
        canvas.extractTextOffline { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    NSSound(named: "Funk")?.play()
                    self.showStatusBanner("Текст на снимке не найден")
                } else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(trimmed, forType: .string)
                    NSSound(named: "Tink")?.play()
                    let linesCount = trimmed.components(separatedBy: .newlines).count
                    self.showStatusBanner("Скопировано строк: \(linesCount)")
                }
            case .failure:
                NSSound(named: "Funk")?.play()
                self.showStatusBanner("Ошибка распознавания")
            }
        }
    }

    @objc private func pinAndClose() {
        guard let finalImage = canvas.renderFinalImage() else { return }
        if let bitmap = finalImage.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL, options: .atomic)
        }
        PinnedScreenshotManager.shared.pin(image: finalImage)
        self.close()
    }

    @objc private func saveAndCopy() {
        guard let finalImage = canvas.renderFinalImage() else { return }

        if let bitmap = finalImage.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL, options: .atomic)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([finalImage])
        NSSound(named: "Pop")?.play()
        self.close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            self.close()
        } else if event.keyCode == 36 { // Enter
            saveAndCopy()
        } else if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "z" {
            canvas.undo()
        } else if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            saveAndCopy()
        } else if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "t" {
            recognizeTextToClipboard()
        } else if let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "1": updateToolSelection(.arrow)
            case "2": updateToolSelection(.rectangle)
            case "3": updateToolSelection(.blur)
            case "4": updateToolSelection(.crop)
            default: super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Унифицированные кнопки 32×32 (SF Symbols 15pt Medium)
private final class DockIconButton: NSView {
    var isSelected: Bool = false { didSet { updateAppearance() } }
    var onHover: ((Bool) -> Void)?
    private var isHovered: Bool = false {
        didSet {
            updateAppearance()
            onHover?(isHovered)
        }
    }
    private let imageView = NSImageView()
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(symbolName: String, tooltip: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: 32).isActive = true
        self.heightAnchor.constraint(equalToConstant: 32).isActive = true
        self.toolTip = tooltip
        self.wantsLayer = true
        self.layer?.cornerRadius = 8

        if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            imageView.image = sym.withSymbolConfiguration(cfg)
        }
        imageView.contentTintColor = .white
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            layer?.borderWidth = 1.0
            layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
            imageView.alphaValue = 1.0
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            layer?.borderWidth = 0.0
            imageView.alphaValue = 1.0
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0.0
            imageView.alphaValue = 0.85
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

private final class DockDotButton: NSView {
    var isSelected: Bool = false { didSet { updateAppearance() } }
    var onHover: ((Bool) -> Void)?
    private var isHovered: Bool = false {
        didSet {
            updateAppearance()
            onHover?(isHovered)
        }
    }
    private let dotView = NSView()
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(dotDiameter: CGFloat, tooltip: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 32))
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: 26).isActive = true
        self.heightAnchor.constraint(equalToConstant: 32).isActive = true
        self.toolTip = tooltip
        self.wantsLayer = true
        self.layer?.cornerRadius = 8

        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.white.cgColor
        dotView.layer?.cornerRadius = dotDiameter / 2
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)
        NSLayoutConstraint.activate([
            dotView.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: dotDiameter),
            dotView.heightAnchor.constraint(equalToConstant: dotDiameter)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            layer?.borderWidth = 1.0
            layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
            dotView.alphaValue = 1.0
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
            layer?.borderWidth = 0.0
            dotView.alphaValue = 0.75
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0.0
            dotView.alphaValue = 0.35
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

private final class DockColorSwatch: NSView {
    var isSelected: Bool { didSet { updateAppearance() } }
    var onHover: ((Bool) -> Void)?
    private var isHovered: Bool = false {
        didSet {
            updateAppearance()
            onHover?(isHovered)
        }
    }
    private let circle = NSView()
    private let ring = NSView()
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(color: NSColor, name: String, isSelected: Bool, onClick: @escaping () -> Void) {
        self.isSelected = isSelected
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: 26).isActive = true
        self.heightAnchor.constraint(equalToConstant: 26).isActive = true
        self.toolTip = name

        ring.wantsLayer = true
        ring.layer?.cornerRadius = 11
        ring.layer?.borderWidth = 1.5
        ring.layer?.borderColor = NSColor.white.cgColor
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)

        circle.wantsLayer = true
        circle.layer?.backgroundColor = color.cgColor
        circle.layer?.cornerRadius = 8.5
        circle.layer?.borderWidth = 1.0
        circle.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        circle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(circle)

        NSLayoutConstraint.activate([
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 22),
            ring.heightAnchor.constraint(equalToConstant: 22),

            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.centerYAnchor.constraint(equalTo: centerYAnchor),
            circle.widthAnchor.constraint(equalToConstant: 17),
            circle.heightAnchor.constraint(equalToConstant: 17)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        ring.isHidden = !isSelected
        circle.layer?.transform = isHovered ? CATransform3DMakeScale(1.12, 1.12, 1.0) : CATransform3DIdentity
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}
