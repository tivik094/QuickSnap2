import Cocoa

// MARK: - Наблюдатель за папкой скриншотов (на базе DispatchSource вместо поллинга)
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()
    private init() {}

    private var activePreview: PreviewPanel?
    private var activeEditor: EditorWindow?
    private var directorySource: DispatchSourceFileSystemObject?
    private var dirFileDescriptor: Int32 = -1
    private var knownFiles: Set<String> = []
    private let watchQueue = DispatchQueue(label: "com.viktor.quicksnap2.dirwatch", qos: .utility)

    var onNewScreenshotCaptured: (() -> Void)?

    func startWatching() {
        stopWatching()

        let dirURL = Config.saveDirectory
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        if let files = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) {
            knownFiles = Set(files)
        }

        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            self?.checkForNewFiles()
        }

        source.setCancelHandler { [weak self] in
            if let descriptor = self?.dirFileDescriptor, descriptor >= 0 {
                close(descriptor)
                self?.dirFileDescriptor = -1
            }
        }

        directorySource = source
        source.resume()
    }

    func stopWatching() {
        directorySource?.cancel()
        directorySource = nil
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
        activeEditor?.close()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.handleNewScreenshot(at: fileURL)
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
            self?.activeEditor?.close()
            let editor = EditorWindow(image: img, fileURL: url)
            editor.makeKeyAndOrderFront(nil)
            self?.activeEditor = editor
        }
        panel.animateIn()
        activePreview = panel
    }
}
