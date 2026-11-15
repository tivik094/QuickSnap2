import Cocoa

// MARK: - Встроенный быстрый редактор (Стрелки, Рамки, Блюр)
enum AnnotationTool: Int {
    case arrow = 0
    case rectangle = 1
    case blur = 2
}

struct AnnotationItem {
    let tool: AnnotationTool
    let start: NSPoint
    let end: NSPoint
    let color: NSColor
}

class EditorCanvasView: NSView {
    let baseImage: NSImage
    var currentTool: AnnotationTool = .arrow
    var currentColor: NSColor = .systemRed
    var annotations: [AnnotationItem] = []
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var blurredImage: NSImage?
    
    init(frame: NSRect, image: NSImage) {
        self.baseImage = image
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.masksToBounds = true
        self.blurredImage = makePixelatedImage(from: image)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func makePixelatedImage(from source: NSImage) -> NSImage? {
        guard let tiff = source.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return nil }
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(18.0, forKey: kCIInputScaleKey)
        guard let output = filter?.outputImage?.cropped(to: ciImage.extent) else { return nil }
        let context = CIContext()
        guard let cgImg = context.createCGImage(output, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImg, size: source.size)
    }
    
    func undo() {
        if !annotations.isEmpty {
            annotations.removeLast()
            needsDisplay = true
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }
    
    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        guard let s = dragStart, let e = dragCurrent else { return }
        if hypot(e.x - s.x, e.y - s.y) > 4 {
            annotations.append(AnnotationItem(tool: currentTool, start: s, end: e, color: currentColor))
        }
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(in: bounds)
        for item in annotations {
            drawAnnotation(item)
        }
        if let s = dragStart, let e = dragCurrent {
            drawAnnotation(AnnotationItem(tool: currentTool, start: s, end: e, color: currentColor))
        }
    }
    
    private func drawAnnotation(_ item: AnnotationItem) {
        switch item.tool {
        case .rectangle:
            let rect = NSRect(
                x: min(item.start.x, item.end.x),
                y: min(item.start.y, item.end.y),
                width: abs(item.end.x - item.start.x),
                height: abs(item.end.y - item.start.y)
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.lineWidth = 3.5
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
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                blurred.draw(in: bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            
        case .arrow:
            drawArrow(from: item.start, to: item.end, color: item.color)
        }
    }
    
    private func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 18.0
        let arrowAngle: CGFloat = .pi / 6.5
        
        let lineEnd = NSPoint(
            x: end.x - (arrowLength * 0.7) * cos(angle),
            y: end.y - (arrowLength * 0.7) * sin(angle)
        )
        
        let path = NSBezierPath()
        path.lineWidth = 4.0
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
    
    func renderFinalImage() -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = bounds.size
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        
        let result = NSImage(size: bounds.size)
        result.addRepresentation(rep)
        return result
    }
}


class EditorWindow: NSWindow {
    private let canvas: EditorCanvasView
    private let fileURL: URL
    private var toolButtons: [AnnotationTool: PillButton] = [:]
    private var colorSwatches: [NSButton] = []
    
    init(image: NSImage, fileURL: URL) {
        self.fileURL = fileURL
        
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let maxW = screenFrame.width * 0.82
        let maxH = screenFrame.height * 0.82 - 64
        
        var imgW = image.size.width
        var imgH = image.size.height
        let ratio = min(maxW / imgW, maxH / imgH, 1.0)
        imgW = max(imgW * ratio, 580)
        imgH = max(imgH * ratio, 260)
        
        let pad: CGFloat = 16
        let toolbarH: CGFloat = 54
        let winSize = NSSize(width: imgW + pad * 2, height: imgH + toolbarH + pad)
        let winOrigin = NSPoint(
            x: screenFrame.midX - winSize.width / 2,
            y: screenFrame.midY - winSize.height / 2
        )
        
        self.canvas = EditorCanvasView(frame: NSRect(x: pad, y: pad, width: imgW, height: imgH), image: image)
        
        super.init(
            contentRect: NSRect(origin: winOrigin, size: winSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        self.title = "QuickSnap — Быстрая разметка"
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0)
        setupToolbar(width: winSize.width, y: imgH + pad + 11, pad: pad)
        self.contentView?.addSubview(canvas)
    }
    
    private func setupToolbar(width: CGFloat, y: CGFloat, pad: CGFloat) {
        guard let root = self.contentView else { return }
        let btnH: CGFloat = 30
        
        let arrowBtn = PillButton(frame: NSRect(x: pad, y: y, width: 96, height: btnH), title: "Стрелка", symbolName: "arrow.up.right") { [weak self] in
            self?.updateToolSelection(.arrow)
        }
        let rectBtn = PillButton(frame: NSRect(x: pad + 104, y: y, width: 88, height: btnH), title: "Рамка", symbolName: "rectangle") { [weak self] in
            self?.updateToolSelection(.rectangle)
        }
        let blurBtn = PillButton(frame: NSRect(x: pad + 200, y: y, width: 84, height: btnH), title: "Блюр", symbolName: "checkerboard.rectangle") { [weak self] in
            self?.updateToolSelection(.blur)
        }
        
        toolButtons[.arrow] = arrowBtn
        toolButtons[.rectangle] = rectBtn
        toolButtons[.blur] = blurBtn
        updateToolSelection(.arrow)
        
        root.addSubview(arrowBtn)
        root.addSubview(rectBtn)
        root.addSubview(blurBtn)
        
        // Разделитель перед палитрой
        let sep = NSView(frame: NSRect(x: pad + 298, y: y + 5, width: 1, height: 20))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        root.addSubview(sep)
        
        // Палитра цветов с выделением активного
        let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow]
        let paletteStartX = pad + 314
        for (idx, color) in colors.enumerated() {
            let swatch = NSButton(frame: NSRect(x: paletteStartX + CGFloat(idx * 30), y: y + 4, width: 22, height: 22))
            swatch.title = ""
            swatch.isBordered = false
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.cgColor
            swatch.layer?.cornerRadius = 11
            swatch.layer?.borderWidth = (idx == 0) ? 2.5 : 1.0
            swatch.layer?.borderColor = (idx == 0) ? NSColor.white.cgColor : NSColor.white.withAlphaComponent(0.35).cgColor
            swatch.tag = idx
            swatch.target = self
            swatch.action = #selector(selectColor(_:))
            colorSwatches.append(swatch)
            root.addSubview(swatch)
        }
        
        // Правая группа: Отмена и Готово
        let doneW: CGFloat = 116
        let undoW: CGFloat = 36
        let doneX = width - pad - doneW
        let undoX = doneX - 8 - undoW
        
        let undoBtn = PillButton(frame: NSRect(x: undoX, y: y, width: undoW, height: btnH), title: nil, symbolName: "arrow.uturn.backward") { [weak self] in
            self?.canvas.undo()
        }
        let doneBtn = PillButton(frame: NSRect(x: doneX, y: y, width: doneW, height: btnH), title: "Готово (⌘C)", symbolName: "checkmark", isAccent: true) { [weak self] in
            self?.saveAndCopy()
        }
        
        root.addSubview(undoBtn)
        root.addSubview(doneBtn)
    }
    
    private func updateToolSelection(_ active: AnnotationTool) {
        canvas.currentTool = active
        for (tool, btn) in toolButtons {
            btn.isSelected = (tool == active)
        }
    }
    
    @objc private func selectColor(_ sender: NSButton) {
        let map: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow]
        guard sender.tag < map.count else { return }
        canvas.currentColor = map[sender.tag]
        for (idx, btn) in colorSwatches.enumerated() {
            btn.layer?.borderWidth = (idx == sender.tag) ? 2.5 : 1.0
            btn.layer?.borderColor = (idx == sender.tag) ? NSColor.white.cgColor : NSColor.white.withAlphaComponent(0.35).cgColor
        }
    }
    
    @objc private func saveAndCopy() {
        let finalImage = canvas.renderFinalImage()
        
        if let tiff = finalImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL)
        }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([finalImage])
        NSSound(named: "Pop")?.play()
        self.close()
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            self.close()
        } else if event.keyCode == 36 { // Enter
            saveAndCopy()
        } else if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "z" {
            canvas.undo()
        } else if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            saveAndCopy()
        } else {
            super.keyDown(with: event)
        }
    }
}

