import Cocoa

// MARK: - Плавающая панель управления записью (Таймер + Пауза + Стоп)
final class RecordingHUDWindow: NSPanel {
    var onMicToggle: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?

    private let dotView = NSView()
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private var micBtn: PillButton!
    private var pauseBtn: PillButton!
    private var stopBtn: PillButton!
    private var micEnabled = false
    private var micMuted = false
    private var lastMicPulse: CFTimeInterval = 0

    func configureMic(enabled: Bool) {
        self.micEnabled = enabled
        self.micMuted = false
        micBtn.alphaValue = enabled ? 1.0 : 0.42
        updateMicAppearance(hasSignal: false)
    }

    func setMicMuted(_ muted: Bool) {
        guard micEnabled else { return }
        self.micMuted = muted
        updateMicAppearance(hasSignal: false)
    }

    private func updateMicAppearance(hasSignal: Bool) {
        let sym = (micEnabled && !micMuted) ? "mic.fill" : "mic.slash.fill"
        let tint: NSColor
        if !micEnabled {
            tint = .systemGray
        } else if micMuted {
            tint = .systemRed
        } else if hasSignal {
            tint = .systemGreen
        } else {
            tint = .white
        }
        micBtn.setSymbol(sym, tintColor: tint)
        if !micEnabled {
            micBtn.toolTip = "Микрофон не был включён при старте записи"
        } else if micMuted {
            micBtn.toolTip = "Микрофон выключен (нажми, чтобы включить)"
        } else {
            micBtn.toolTip = "Микрофон включён (нажми, чтобы выключить звук)"
        }
    }

    func notifyMicSignal(active: Bool) {
        guard micEnabled, !micMuted else { return }
        let now = CACurrentMediaTime()
        if active {
            lastMicPulse = now
            updateMicAppearance(hasSignal: true)
        } else if now - lastMicPulse > 0.35 {
            updateMicAppearance(hasSignal: false)
        }
    }

    init(visibleFrame: CGRect) {
        let width: CGFloat = 254
        let height: CGFloat = 46
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.minY + 24

        super.init(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
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

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = height / 2
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1.0
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        dotView.frame = NSRect(x: 16, y: (height - 10) / 2, width: 10, height: 10)
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 5
        dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        root.addSubview(dotView)

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.frame = NSRect(x: 32, y: (height - 18) / 2, width: 52, height: 18)
        root.addSubview(timeLabel)

        micBtn = PillButton(
            frame: NSRect(x: 88, y: 8, width: 34, height: 30),
            title: nil,
            symbolName: "mic.slash.fill",
            cornerRadius: 15
        ) { [weak self] in
            self?.onMicToggle?()
        }
        root.addSubview(micBtn)
        configureMic(enabled: false)

        pauseBtn = PillButton(
            frame: NSRect(x: 128, y: 8, width: 34, height: 30),
            title: nil,
            symbolName: "pause.fill",
            cornerRadius: 15
        ) { [weak self] in
            self?.onPauseToggle?()
        }
        pauseBtn.toolTip = "Пауза / Продолжить"
        root.addSubview(pauseBtn)

        stopBtn = PillButton(
            frame: NSRect(x: 168, y: 8, width: 74, height: 30),
            title: "Стоп",
            symbolName: "stop.fill",
            isDestructive: true,
            cornerRadius: 15
        ) { [weak self] in
            self?.onStop?()
        }
        stopBtn.toolTip = "Остановить и сохранить MP4"
        root.addSubview(stopBtn)

        self.contentView = root
    }

    func update(isPaused: Bool, timeText: String) {
        timeLabel.stringValue = isPaused ? "ПАУЗА" : timeText
        dotView.layer?.backgroundColor = (isPaused ? NSColor.systemYellow : NSColor.systemRed).cgColor

        pauseBtn.setSymbol(isPaused ? "play.fill" : "pause.fill")
    }
}
