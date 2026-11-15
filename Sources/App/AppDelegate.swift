import Cocoa
import Carbon
import ServiceManagement

// MARK: - Приложение в Menu Bar с красивой иконкой и анимацией
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    private var isRecordingVideo = false
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        ScreenshotWatcher.shared.onNewScreenshotCaptured = { [weak self] in
            self?.pulseStatusIcon()
        }
        Config.ensureInitialDirectorySetup()
        ScreenshotWatcher.shared.startWatching()
        HotKeyManager.shared.registerDefaults()
        if #available(macOS 13.0, *) {
            ScreenRecorderManager.shared.onRecordingStateChanged = { [weak self] recording, isPaused, timeText in
                self?.updateRecordingIndicator(recording: recording, isPaused: isPaused, timeText: timeText)
            }
        }
        enableLaunchAtLogin()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        if let button = statusItem.button {
            button.image = makeMenuBarIcon(isSuccess: false)
            button.imageScaling = .scaleNone
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
    }
    
    @objc private func togglePopover(_ sender: AnyObject?) {
        if isRecordingVideo {
            if #available(macOS 13.0, *) {
                ScreenRecorderManager.shared.stopRecording()
            }
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let vc = MenuPopoverViewController()
            vc.onClosePopover = { [weak self] in
                self?.popover.performClose(nil)
            }
            popover.contentViewController = vc
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    private func updateRecordingIndicator(recording: Bool, isPaused: Bool, timeText: String) {
        isRecordingVideo = recording
        guard let button = statusItem.button else { return }
        if recording {
            statusItem.length = NSStatusItem.variableLength
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            let symName = isPaused ? "pause.circle.fill" : "record.circle.fill"
            let dot = NSImage(systemSymbolName: symName, accessibilityDescription: "Recording")?.withSymbolConfiguration(cfg)
            dot?.isTemplate = false
            button.image = dot
            button.contentTintColor = isPaused ? .systemYellow : .systemRed
            button.imagePosition = .imageLeading
            button.title = isPaused ? " ПАУЗА" : " \(timeText)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.toolTip = "Нажмите, чтобы остановить запись"
        } else {
            statusItem.length = 26
            button.title = ""
            button.contentTintColor = nil
            button.imagePosition = .imageOnly
            button.image = makeMenuBarIcon(isSuccess: false)
            button.toolTip = "QuickSnap 2.0"
        }
    }

    private func makeMenuBarIcon(isSuccess: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // 1. Четыре уголка видоискателя (18x18, толщина 1.6pt, выровнено по сетке)
            let framePath = NSBezierPath()
            framePath.lineWidth = 1.6
            framePath.lineCapStyle = .round
            framePath.lineJoinStyle = .round

            let m: CGFloat = 1.2
            let len: CGFloat = 4.2
            let r: CGFloat = 2.0
            let maxX = size.width - m
            let maxY = size.height - m

            // Левый верхний
            framePath.move(to: NSPoint(x: m, y: maxY - len))
            framePath.line(to: NSPoint(x: m, y: maxY - r))
            framePath.curve(to: NSPoint(x: m + r, y: maxY), controlPoint1: NSPoint(x: m, y: maxY), controlPoint2: NSPoint(x: m, y: maxY))
            framePath.line(to: NSPoint(x: m + len, y: maxY))

            // Правый верхний
            framePath.move(to: NSPoint(x: maxX - len, y: maxY))
            framePath.line(to: NSPoint(x: maxX - r, y: maxY))
            framePath.curve(to: NSPoint(x: maxX, y: maxY - r), controlPoint1: NSPoint(x: maxX, y: maxY), controlPoint2: NSPoint(x: maxX, y: maxY))
            framePath.line(to: NSPoint(x: maxX, y: maxY - len))

            // Правый нижний
            framePath.move(to: NSPoint(x: maxX, y: m + len))
            framePath.line(to: NSPoint(x: maxX, y: m + r))
            framePath.curve(to: NSPoint(x: maxX - r, y: m), controlPoint1: NSPoint(x: maxX, y: m), controlPoint2: NSPoint(x: maxX, y: m))
            framePath.line(to: NSPoint(x: maxX - len, y: m))

            // Левый нижний
            framePath.move(to: NSPoint(x: m + len, y: m))
            framePath.line(to: NSPoint(x: m + r, y: m))
            framePath.curve(to: NSPoint(x: m, y: m + r), controlPoint1: NSPoint(x: m, y: m), controlPoint2: NSPoint(x: m, y: m))
            framePath.line(to: NSPoint(x: m, y: m + len))

            framePath.stroke()

            if isSuccess {
                let check = NSBezierPath()
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.move(to: NSPoint(x: 5.5, y: 9.0))
                check.line(to: NSPoint(x: 8.0, y: 6.5))
                check.line(to: NSPoint(x: 12.8, y: 11.5))
                check.stroke()
            } else {
                // 2. Крупный корпус камеры внутри рамки (11.6 x 8.0)
                let bodyRect = NSRect(x: 3.2, y: 4.4, width: 11.6, height: 8.0)
                let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 1.6, yRadius: 1.6)
                bodyPath.fill()

                // Выступ видоискателя сверху камеры
                let topRect = NSRect(x: 6.7, y: 12.1, width: 4.6, height: 1.6)
                NSBezierPath(roundedRect: topRect, xRadius: 0.7, yRadius: 0.7).fill()

                // Прозрачный объектив (крупный вырез через destinationOut)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let outerLens = NSBezierPath(ovalIn: NSRect(x: 6.5, y: 5.9, width: 5.0, height: 5.0))
                outerLens.fill()

                // Точка в центре объектива
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                let innerLens = NSBezierPath(ovalIn: NSRect(x: 7.9, y: 7.3, width: 2.2, height: 2.2))
                innerLens.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func pulseStatusIcon() {
        guard let button = statusItem.button else { return }
        button.image = makeMenuBarIcon(isSuccess: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            button.image = self.makeMenuBarIcon(isSuccess: false)
        }
    }
    
    private func enableLaunchAtLogin() {
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}

