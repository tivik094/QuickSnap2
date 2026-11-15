import Cocoa

// MARK: - Наблюдатель за папкой скриншотов
class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()
    private var activePreview: PreviewPanel?
    private var activeEditor: EditorWindow?
    private var pollTimer: Timer?
    private var knownFiles: Set<String> = []
    var onNewScreenshotCaptured: (() -> Void)?
    
    func startWatching() {
        try? FileManager.default.createDirectory(at: Config.saveDirectory, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: Config.saveDirectory.path) {
            knownFiles = Set(files)
        }
        
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkForNewFiles()
        }
    }
    
    func recentScreenshots(limit: Int = 4) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: Config.saveDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        return urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return d1 > d2
            }
            .prefix(limit)
            .map { $0 }
    }
    
    func openEditor(for url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let logicalSize = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        let image = NSImage(cgImage: cgImage, size: logicalSize)
        
        NSApp.activate(ignoringOtherApps: true)
        let editor = EditorWindow(image: image, fileURL: url)
        editor.makeKeyAndOrderFront(nil)
        self.activeEditor = editor
    }
    
    private func checkForNewFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Config.saveDirectory.path) else { return }
        let currentSet = Set(files)
        let added = currentSet.subtracting(knownFiles)
        knownFiles = currentSet
        
        for fileName in added where fileName.hasSuffix(".png") && !fileName.hasPrefix(".") {
            let fileURL = Config.saveDirectory.appendingPathComponent(fileName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.handleNewScreenshot(at: fileURL)
            }
        }
    }
    
    private func handleNewScreenshot(at fileURL: URL) {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let logicalSize = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: logicalSize)
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        NSSound(named: "Pop")?.play()
        onNewScreenshotCaptured?()
        
        activePreview?.orderOut(nil)
        let panel = PreviewPanel(image: image, fileURL: fileURL, pixelSize: pixelSize)
        panel.onEditRequested = { [weak self] img, url in
            NSApp.activate(ignoringOtherApps: true)
            let editor = EditorWindow(image: img, fileURL: url)
            editor.makeKeyAndOrderFront(nil)
            self?.activeEditor = editor
        }
        panel.animateIn()
        activePreview = panel
    }
}

