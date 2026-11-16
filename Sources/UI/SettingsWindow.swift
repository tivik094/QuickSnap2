import Cocoa
import ServiceManagement
import Carbon

enum SettingsTab: Int {
    case general = 0
    case video = 1
    case hotkeys = 2
    case about = 3
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private init() {}

    private var window: SettingsWindow?

    func show(tab: SettingsTab = .general) {
        NSApp.activate(ignoringOtherApps: true)
        if let win = window {
            win.selectTab(tab)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let win = SettingsWindow(initialTab: tab)
        win.onClose = { [weak self] in
            self?.window = nil
        }
        self.window = win
        win.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?

    private var currentTab: SettingsTab
    private var tabButtons: [SidebarTabItem] = []
    private let headerTitle = NSTextField(labelWithString: "Общий")
    private let contentContainer = NSView()
    private var pathField: NSTextField?
    private var activeRecorder: ShortcutRecorderButton?

    private let accentColor = NSColor(calibratedRed: 0.23, green: 0.54, blue: 0.98, alpha: 1.0)

    init(initialTab: SettingsTab) {
        self.currentTab = initialTab
        let width: CGFloat = 620
        let height: CGFloat = 390

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.center()
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.appearance = NSAppearance(named: .darkAqua)
        self.isReleasedWhenClosed = false
        self.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Левый сайдбар
        let sidebarW: CGFloat = 188
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: height))
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1.0).cgColor

        let items: [(SettingsTab, String, String)] = [
            (.general, "Общий", "slider.horizontal.3"),
            (.video, "Видео", "video"),
            (.hotkeys, "Горячие клавиши", "command"),
            (.about, "О программе", "info.circle")
        ]

        for (idx, item) in items.enumerated() {
            let y = height - 72 - CGFloat(idx) * 38
            let btn = SidebarTabItem(
                frame: NSRect(x: 12, y: y, width: sidebarW - 24, height: 32),
                title: item.1,
                symbol: item.2,
                accentColor: accentColor
            ) { [weak self] in
                self?.selectTab(item.0)
            }
            sidebar.addSubview(btn)
            tabButtons.append(btn)
        }

        root.addSubview(sidebar)

        let vSep = NSBox(frame: NSRect(x: sidebarW, y: 0, width: 1, height: height))
        vSep.boxType = .separator
        root.addSubview(vSep)

        // Правая область
        let rightX = sidebarW + 1
        let rightW = width - rightX
        let rightPane = NSView(frame: NSRect(x: rightX, y: 0, width: rightW, height: height))
        rightPane.wantsLayer = true
        rightPane.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1.0).cgColor

        headerTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        headerTitle.textColor = NSColor.white.withAlphaComponent(0.75)
        headerTitle.frame = NSRect(x: 24, y: height - 34, width: 240, height: 18)
        rightPane.addSubview(headerTitle)

        let hSep = NSBox(frame: NSRect(x: 0, y: height - 44, width: rightW, height: 1))
        hSep.boxType = .separator
        rightPane.addSubview(hSep)

        contentContainer.frame = NSRect(x: 0, y: 0, width: rightW, height: height - 45)
        rightPane.addSubview(contentContainer)
        root.addSubview(rightPane)

        self.contentView = root
        selectTab(initialTab)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        activeRecorder?.stopRecording(cancelled: true)
        self.orderOut(nil)
        // Вызываем onClose, чтобы SettingsWindowController освободил окно при закрытии крестиком
        onClose?()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func selectTab(_ tab: SettingsTab) {
        activeRecorder?.stopRecording(cancelled: true)
        activeRecorder = nil
        currentTab = tab
        for (idx, btn) in tabButtons.enumerated() {
            btn.isSelected = (idx == tab.rawValue)
        }

        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        switch tab {
        case .general:
            headerTitle.stringValue = "Общий"
            buildGeneralTab()
        case .video:
            headerTitle.stringValue = "Видео"
            buildVideoTab()
        case .hotkeys:
            headerTitle.stringValue = "Горячие клавиши"
            buildHotkeysTab()
        case .about:
            headerTitle.stringValue = "О программе"
            buildAboutTab()
        }
    }

    // MARK: - Вкладка «Общий»
    private func buildGeneralTab() {
        let w = contentContainer.bounds.width
        let h = contentContainer.bounds.height

        let launchLabel = makeLabel("Открывать приложение при входе в систему", size: 13, weight: .medium, color: .white)
        launchLabel.frame = NSRect(x: 24, y: h - 46, width: w - 96, height: 18)
        contentContainer.addSubview(launchLabel)

        let launchToggle = AccentToggle(
            frame: NSRect(x: w - 66, y: h - 49, width: 42, height: 24),
            isOn: SMAppService.mainApp.status == .enabled,
            accentColor: accentColor
        ) { isOn in
            do {
                if isOn {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {}
        }
        contentContainer.addSubview(launchToggle)

        let sep = NSBox(frame: NSRect(x: 24, y: h - 68, width: w - 48, height: 1))
        sep.boxType = .separator
        contentContainer.addSubview(sep)

        let locTitle = makeLabel("Папка сохранения", size: 13, weight: .medium, color: .white)
        locTitle.frame = NSRect(x: 24, y: h - 98, width: 200, height: 18)
        contentContainer.addSubview(locTitle)

        let btnWidth: CGFloat = 104
        let pathBoxWidth = w - 48 - btnWidth - 10
        let pathBox = NSView(frame: NSRect(x: 24, y: h - 138, width: pathBoxWidth, height: 32))
        pathBox.wantsLayer = true
        pathBox.layer?.cornerRadius = 8
        pathBox.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor
        pathBox.layer?.borderWidth = 1
        pathBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let tf = makeLabel(Config.saveDirectory.path, size: 12, weight: .regular, color: NSColor.white.withAlphaComponent(0.9))
        tf.lineBreakMode = .byTruncatingMiddle
        tf.frame = NSRect(x: 10, y: 7, width: pathBoxWidth - 20, height: 18)
        pathBox.addSubview(tf)
        self.pathField = tf
        contentContainer.addSubview(pathBox)

        let changeBtn = PillButton(
            frame: NSRect(x: w - 24 - btnWidth, y: h - 138, width: btnWidth, height: 32),
            title: "Изменить",
            symbolName: "folder",
            cornerRadius: 8
        ) { [weak self] in
            self?.chooseFolder()
        }
        contentContainer.addSubview(changeBtn)
    }

    // MARK: - Вкладка «Видео»
    private func buildVideoTab() {
        let w = contentContainer.bounds.width
        let h = contentContainer.bounds.height

        let fpsLabel = makeLabel("Частота кадров (FPS)", size: 13, weight: .medium, color: .white)
        fpsLabel.frame = NSRect(x: 24, y: h - 46, width: 200, height: 18)
        contentContainer.addSubview(fpsLabel)

        let fpsSeg = AccentSegmentedControl(
            frame: NSRect(x: w - 164, y: h - 51, width: 140, height: 28),
            options: ["30 FPS", "60 FPS"],
            selectedIndex: (Config.videoFPS == 30) ? 0 : 1,
            accentColor: accentColor
        ) { idx in
            Config.videoFPS = (idx == 0) ? 30 : 60
        }
        contentContainer.addSubview(fpsSeg)

        let cursorLabel = makeLabel("Показывать курсор мыши на записи", size: 13, weight: .medium, color: .white)
        cursorLabel.frame = NSRect(x: 24, y: h - 90, width: 280, height: 18)
        contentContainer.addSubview(cursorLabel)

        let cursorToggle = AccentToggle(
            frame: NSRect(x: w - 66, y: h - 93, width: 42, height: 24),
            isOn: Config.videoShowCursor,
            accentColor: accentColor
        ) { isOn in
            Config.videoShowCursor = isOn
        }
        contentContainer.addSubview(cursorToggle)

        let sep = NSBox(frame: NSRect(x: 24, y: h - 114, width: w - 48, height: 1))
        sep.boxType = .separator
        contentContainer.addSubview(sep)

        let askLabel = makeLabel("Спрашивать про аудио перед стартом", size: 13, weight: .medium, color: .white)
        askLabel.frame = NSRect(x: 24, y: h - 146, width: 290, height: 18)
        contentContainer.addSubview(askLabel)

        let askToggle = AccentToggle(
            frame: NSRect(x: w - 66, y: h - 149, width: 42, height: 24),
            isOn: Config.videoAskAudioBeforeRecord,
            accentColor: accentColor
        ) { isOn in
            Config.videoAskAudioBeforeRecord = isOn
        }
        contentContainer.addSubview(askToggle)

        let sysLabel = makeLabel("Записывать звук приложений (системный)", size: 13, weight: .regular, color: NSColor.white.withAlphaComponent(0.75))
        sysLabel.frame = NSRect(x: 24, y: h - 186, width: 290, height: 18)
        contentContainer.addSubview(sysLabel)

        let sysToggle = AccentToggle(
            frame: NSRect(x: w - 66, y: h - 189, width: 42, height: 24),
            isOn: Config.videoCaptureSystemAudio,
            accentColor: accentColor
        ) { isOn in
            Config.videoCaptureSystemAudio = isOn
        }
        contentContainer.addSubview(sysToggle)

        let micLabel = makeLabel("Записывать голос с микрофона", size: 13, weight: .regular, color: NSColor.white.withAlphaComponent(0.75))
        micLabel.frame = NSRect(x: 24, y: h - 224, width: 290, height: 18)
        contentContainer.addSubview(micLabel)

        let micToggle = AccentToggle(
            frame: NSRect(x: w - 66, y: h - 227, width: 42, height: 24),
            isOn: Config.videoCaptureMicrophone,
            accentColor: accentColor
        ) { isOn in
            Config.videoCaptureMicrophone = isOn
        }
        contentContainer.addSubview(micToggle)
    }

    // MARK: - Вкладка «Горячие клавиши»
    private func buildHotkeysTab() {
        let w = contentContainer.bounds.width
        let h = contentContainer.bounds.height

        let hint = makeLabel("Кликни по кнопке и нажми новое сочетание с ⌘, ⌥, ⌃ или ⇧", size: 11.5, weight: .regular, color: NSColor.white.withAlphaComponent(0.6))
        hint.frame = NSRect(x: 24, y: h - 38, width: w - 48, height: 16)
        contentContainer.addSubview(hint)

        let rows: [(String, KeyShortcut, (KeyShortcut) -> Void)] = [
            ("Снимок выбранной области", Config.areaShortcut, { Config.areaShortcut = $0 }),
            ("Снимок выбранного окна", Config.windowShortcut, { Config.windowShortcut = $0 }),
            ("Запись видео (Старт / Стоп)", Config.videoShortcut, { Config.videoShortcut = $0 })
        ]

        for (idx, row) in rows.enumerated() {
            let y = h - 84 - CGFloat(idx) * 48

            let title = makeLabel(row.0, size: 13, weight: .medium, color: .white)
            title.frame = NSRect(x: 24, y: y + 6, width: w - 176, height: 18)
            contentContainer.addSubview(title)

            let recorder = ShortcutRecorderButton(
                frame: NSRect(x: w - 144, y: y, width: 120, height: 30),
                shortcut: row.1,
                accentColor: accentColor,
                onActivate: { [weak self] activeBtn in
                    if let prev = self?.activeRecorder, prev !== activeBtn {
                        prev.stopRecording(cancelled: true)
                    }
                    self?.activeRecorder = activeBtn
                },
                onShortcutRecorded: { [weak self] newShortcut in
                    self?.activeRecorder = nil
                    row.2(newShortcut)
                    NSSound(named: "Tink")?.play()
                }
            )
            contentContainer.addSubview(recorder)
        }

        let sep = NSBox(frame: NSRect(x: 24, y: h - 226, width: w - 48, height: 1))
        sep.boxType = .separator
        contentContainer.addSubview(sep)

        let resetBtn = PillButton(
            frame: NSRect(x: 24, y: h - 270, width: 196, height: 32),
            title: "Сбросить по умолчанию",
            symbolName: "arrow.counterclockwise",
            cornerRadius: 8
        ) { [weak self] in
            Config.resetShortcutsToDefaults()
            NSSound(named: "Pop")?.play()
            self?.selectTab(.hotkeys)
        }
        contentContainer.addSubview(resetBtn)
    }

    // MARK: - Вкладка «О программе»
    private func buildAboutTab() {
        let w = contentContainer.bounds.width
        let h = contentContainer.bounds.height

        let name = makeLabel("QuickSnap 2.0", size: 16, weight: .semibold, color: .white)
        name.frame = NSRect(x: 24, y: h - 48, width: 250, height: 22)
        contentContainer.addSubview(name)

        let desc = NSTextField(wrappingLabelWithString: "Нативная утилита macOS для быстрых скриншотов, аннотаций и записи экрана в MP4 с системным звуком и микрофоном на базе ScreenCaptureKit.")
        desc.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        desc.textColor = NSColor.white.withAlphaComponent(0.72)
        desc.frame = NSRect(x: 24, y: h - 118, width: w - 48, height: 60)
        contentContainer.addSubview(desc)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку для сохранения"
        panel.prompt = "Выбрать"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Config.saveDirectory

        if panel.runModal() == .OK, let url = panel.url {
            Config.saveDirectory = url
            pathField?.stringValue = url.path
            NSSound(named: "Glass")?.play()
        }
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }
}

// MARK: - Интерактивная кнопка записи горячей клавиши
private final class ShortcutRecorderButton: NSView {
    private var shortcut: KeyShortcut
    private let accentColor: NSColor
    private let onActivate: (ShortcutRecorderButton) -> Void
    private let onShortcutRecorded: (KeyShortcut) -> Void

    private let bgView = NSView()
    private let label = NSTextField(labelWithString: "")
    private var isRecordingKeys = false
    private var localMonitor: Any?

    init(
        frame: NSRect,
        shortcut: KeyShortcut,
        accentColor: NSColor,
        onActivate: @escaping (ShortcutRecorderButton) -> Void,
        onShortcutRecorded: @escaping (KeyShortcut) -> Void
    ) {
        self.shortcut = shortcut
        self.accentColor = accentColor
        self.onActivate = onActivate
        self.onShortcutRecorded = onShortcutRecorded
        super.init(frame: frame)

        bgView.frame = bounds
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 8
        bgView.layer?.borderWidth = 1
        addSubview(bgView)

        label.alignment = .center
        label.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        label.frame = NSRect(x: 6, y: 6, width: frame.width - 12, height: 18)
        addSubview(label)

        refreshUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeMonitor()
    }

    private func refreshUI() {
        if isRecordingKeys {
            bgView.layer?.backgroundColor = accentColor.withAlphaComponent(0.22).cgColor
            bgView.layer?.borderColor = accentColor.cgColor
            label.stringValue = "Нажмите клавиши…"
            label.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            label.textColor = .white
        } else {
            bgView.layer?.backgroundColor = NSColor(calibratedWhite: 0.24, alpha: 1.0).cgColor
            bgView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            label.stringValue = shortcut.displayString
            label.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
            label.textColor = .white
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if isRecordingKeys {
            stopRecording(cancelled: true)
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecordingKeys = true
        onActivate(self)
        HotKeyManager.shared.unregisterAll()
        refreshUI()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecordingKeys else { return event }

            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording(cancelled: true)
                return nil
            }

            let mods = KeyShortcut.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else {
                NSSound.beep()
                return nil
            }

            let newShortcut = KeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
            self.shortcut = newShortcut
            self.stopRecording(cancelled: false)
            self.onShortcutRecorded(newShortcut)
            return nil
        }
    }

    func stopRecording(cancelled: Bool) {
        guard isRecordingKeys else { return }
        isRecordingKeys = false
        removeMonitor()
        if cancelled {
            HotKeyManager.shared.registerDefaults()
        }
        refreshUI()
    }

    private func removeMonitor() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }
}

// MARK: - Кнопка вкладки сайдбара без размытия текста
private final class SidebarTabItem: NSView {
    private let bgView = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let accentColor: NSColor
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    var isSelected: Bool = false {
        didSet { updateStyle() }
    }

    init(frame: NSRect, title: String, symbol: String, accentColor: NSColor, onClick: @escaping () -> Void) {
        self.accentColor = accentColor
        self.onClick = onClick
        super.init(frame: frame)

        bgView.frame = bounds
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 8
        addSubview(bgView)

        if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            iconView.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        }
        iconView.frame = NSRect(x: 10, y: 8, width: 16, height: 16)
        addSubview(iconView)

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 30, y: 7, width: frame.width - 34, height: 18)
        addSubview(label)

        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateStyle() {
        if isSelected {
            bgView.layer?.backgroundColor = accentColor.cgColor
            label.textColor = .white
            iconView.contentTintColor = .white
        } else {
            bgView.layer?.backgroundColor = NSColor.white.withAlphaComponent(isHovered ? 0.08 : 0.0).cgColor
            label.textColor = NSColor.white.withAlphaComponent(0.78)
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyle()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }
}

// MARK: - Яркий нативный тумблер
private final class AccentToggle: NSView {
    private var isOn: Bool
    private let accentColor: NSColor
    private let onChange: (Bool) -> Void
    private let knob = NSView()

    init(frame: NSRect, isOn: Bool, accentColor: NSColor, onChange: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.accentColor = accentColor
        self.onChange = onChange
        super.init(frame: frame)

        self.wantsLayer = true
        self.layer?.cornerRadius = frame.height / 2

        let knobSize = frame.height - 4
        knob.frame = NSRect(x: isOn ? frame.width - knobSize - 2 : 2, y: 2, width: knobSize, height: knobSize)
        knob.wantsLayer = true
        knob.layer?.cornerRadius = knobSize / 2
        knob.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(knob)

        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance(animated: Bool) {
        let knobSize = bounds.height - 4
        let targetX: CGFloat = isOn ? bounds.width - knobSize - 2 : 2
        let bgColor = isOn ? accentColor.cgColor : NSColor.white.withAlphaComponent(0.22).cgColor

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.layer?.backgroundColor = bgColor
                self.knob.animator().frame.origin.x = targetX
            }
        } else {
            self.layer?.backgroundColor = bgColor
            self.knob.frame.origin.x = targetX
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            isOn.toggle()
            updateAppearance(animated: true)
            onChange(isOn)
        }
    }
}

// MARK: - Чёткий переключатель сегментов (30 FPS / 60 FPS) без размытия текста
private final class AccentSegmentedControl: NSView {
    private let bgView = NSView()
    private let thumbView = NSView()
    private var labels: [NSTextField] = []
    private var selectedIndex: Int
    private let accentColor: NSColor
    private let onSelect: (Int) -> Void

    init(frame: NSRect, options: [String], selectedIndex: Int, accentColor: NSColor, onSelect: @escaping (Int) -> Void) {
        self.selectedIndex = selectedIndex
        self.accentColor = accentColor
        self.onSelect = onSelect
        super.init(frame: frame)

        bgView.frame = bounds
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 8
        bgView.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor
        bgView.layer?.borderWidth = 1
        bgView.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        addSubview(bgView)

        let segW = floor((frame.width - 4) / CGFloat(options.count))
        thumbView.frame = NSRect(x: 2 + CGFloat(selectedIndex) * segW, y: 2, width: segW, height: frame.height - 4)
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 6
        thumbView.layer?.backgroundColor = accentColor.cgColor
        addSubview(thumbView)

        for (idx, title) in options.enumerated() {
            let lbl = NSTextField(labelWithString: title)
            lbl.alignment = .center
            lbl.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            lbl.frame = NSRect(x: 2 + CGFloat(idx) * segW, y: floor((frame.height - 16) / 2), width: segW, height: 16)
            addSubview(lbl)
            labels.append(lbl)
        }
        updateTextColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTextColors() {
        for (idx, lbl) in labels.enumerated() {
            lbl.textColor = (idx == selectedIndex) ? .white : NSColor.white.withAlphaComponent(0.65)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt), !labels.isEmpty else { return }
        let segW = floor((bounds.width - 4) / CGFloat(labels.count))
        let idx = min(labels.count - 1, max(0, Int((pt.x - 2) / segW)))
        guard idx != selectedIndex else { return }
        selectedIndex = idx
        updateTextColors()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.thumbView.animator().frame.origin.x = 2 + CGFloat(idx) * segW
        }
        onSelect(idx)
    }
}
