import Cocoa
import ScreenCaptureKit
import AVFoundation

@available(macOS 13.0, *)
final class ScreenRecorderManager: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let shared = ScreenRecorderManager()
    private override init() { super.init() }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sysAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private weak var activeHUD: RecordingHUDWindow?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?

    // Защита mutable-состояния при обращении из main thread и mediaQueue
    private let stateLock = NSLock()
    private var _isRecording = false
    private var _isPaused = false

    private(set) var isRecording: Bool {
        get { stateLock.withLock { _isRecording } }
        set { stateLock.withLock { _isRecording = newValue } }
    }

    private(set) var isPaused: Bool {
        get { stateLock.withLock { _isPaused } }
        set { stateLock.withLock { _isPaused = newValue } }
    }

    private var sessionStarted = false
    private var pauseStartPTS: CMTime?
    private var totalPausedDuration: CMTime = .zero
    private var accumulatedSeconds: TimeInterval = 0
    private var segmentStartDate: Date?

    private var timer: Timer?
    private var selectionWindow: RegionSelectionWindow?
    private var hudWindow: RecordingHUDWindow?

    private let mediaQueue = DispatchQueue(label: "com.viktor.quicksnap2.videorecord", qos: .userInitiated)

    var onRecordingStateChanged: ((Bool, Bool, String) -> Void)?

    func toggleRecordingFlow() {
        if isRecording {
            stopRecording()
        } else {
            beginRegionSelection()
        }
    }

    func togglePause() {
        guard isRecording else { return }
        if isPaused {
            isPaused = false
            segmentStartDate = Date()
            NSSound(named: "Tink")?.play()
        } else {
            isPaused = true
            if let start = segmentStartDate {
                accumulatedSeconds += Date().timeIntervalSince(start)
                segmentStartDate = nil
            }
            NSSound(named: "Pop")?.play()
        }
        updateUIState()
    }

    private func currentFormattedTime() -> String {
        var total = accumulatedSeconds
        if !isPaused, let start = segmentStartDate {
            total += Date().timeIntervalSince(start)
        }
        let sec = Int(total)
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }

    private func updateUIState() {
        let timeStr = currentFormattedTime()
        let rec = isRecording
        let paused = isPaused
        if Thread.isMainThread {
            hudWindow?.update(isPaused: paused, timeText: timeStr)
            onRecordingStateChanged?(rec, paused, timeStr)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.hudWindow?.update(isPaused: paused, timeText: timeStr)
                self?.onRecordingStateChanged?(rec, paused, timeStr)
            }
        }
    }

    // 1. Оверлей выбора области для записи
    private func beginRegionSelection() {
        // Определяем экран под курсором мыши, а не просто первый/main
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let targetScreen = screen else { return }

        selectionWindow?.close()

        let win = RegionSelectionWindow(screen: targetScreen)
        win.onRegionSelected = { [weak self] rect in
            self?.selectionWindow = nil
            guard rect.width >= 32, rect.height >= 32 else { return }
            self?.promptAudioAndStart(rect: rect, on: targetScreen)
        }
        win.onCancelled = { [weak self] in
            self?.selectionWindow = nil
        }
        selectionWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // 2. Уточнение перед записью: писать ли аудио
    private func promptAudioAndStart(rect: CGRect, on screen: NSScreen) {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let scale = screen.backingScaleFactor

        if !Config.videoAskAudioBeforeRecord {
            Task {
                await startRecording(
                    rect: rect,
                    displayID: displayID,
                    screenFrame: screenFrame,
                    visibleFrame: visibleFrame,
                    scale: scale,
                    captureSystemAudio: Config.videoCaptureSystemAudio,
                    captureMic: Config.videoCaptureMicrophone
                )
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Записывать аудио вместе с видео?"
        alert.informativeText = "Выбери нужные источники звука для этого ролика."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Начать запись")
        alert.addButton(withTitle: "Отмена")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let sysCheck = NSButton(checkboxWithTitle: "Звук приложений (системный аудиопоток)", target: nil, action: nil)
        sysCheck.state = Config.videoCaptureSystemAudio ? .on : .off

        let micCheck = NSButton(checkboxWithTitle: "Микрофон (голос)", target: nil, action: nil)
        micCheck.state = Config.videoCaptureMicrophone ? .on : .off

        stack.addArrangedSubview(sysCheck)
        stack.addArrangedSubview(micCheck)
        alert.accessoryView = stack

        let res = alert.runModal()
        guard res == .alertFirstButtonReturn else { return }

        let useSys = (sysCheck.state == .on)
        let useMic = (micCheck.state == .on)
        Config.videoCaptureSystemAudio = useSys
        Config.videoCaptureMicrophone = useMic

        Task {
            await startRecording(
                rect: rect,
                displayID: displayID,
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                scale: scale,
                captureSystemAudio: useSys,
                captureMic: useMic
            )
        }
    }

    // 3. Запуск SCStream (+ AVCaptureSession для микрофона) + AVAssetWriter в MP4
    private func startRecording(
        rect: CGRect,
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        scale: CGFloat,
        captureSystemAudio: Bool,
        captureMic: Bool
    ) async {
        do {
            var micAllowed = false
            if captureMic {
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .authorized {
                    micAllowed = true
                } else if status == .notDetermined {
                    micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
                } else {
                    await MainActor.run {
                        NSApp.activate(ignoringOtherApps: true)
                        let a = NSAlert()
                        a.messageText = "Нет доступа к микрофону"
                        a.informativeText = "Разреши доступ для QuickSnap в Системных настройках → Конфиденциальность и безопасность → Микрофон."
                        a.runModal()
                    }
                    return
                }
            }

            guard ScreenCaptureManager.ensureScreenCapturePermission() else { return }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }

            let pixelW = (Int(rect.width * scale) / 2) * 2
            let pixelH = (Int(rect.height * scale) / 2) * 2
            guard pixelW >= 32, pixelH >= 32 else { return }

            let flippedY = screenFrame.height - (rect.origin.y - screenFrame.origin.y) - rect.height
            let sourceRect = CGRect(
                x: rect.origin.x - screenFrame.origin.x,
                y: flippedY,
                width: rect.width,
                height: rect.height
            )

            let fps = Config.videoFPS
            let config = SCStreamConfiguration()
            config.sourceRect = sourceRect
            config.width = pixelW
            config.height = pixelH
            config.scalesToFit = false
            config.queueDepth = 6
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = Config.videoShowCursor

            if captureSystemAudio {
                config.capturesAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
            }

            Config.ensureInitialDirectorySetup()
            let url = Config.saveDirectory.appendingPathComponent("QuickSnap_\(Self.fileDateFormatter.string(from: Date())).mp4")
            try? FileManager.default.removeItem(at: url)
            self.outputURL = url

            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let fpsFactor = (fps == 30) ? 9 : 15
            let targetBitrate = max(fps == 30 ? 7_000_000 : 12_000_000, pixelW * pixelH * fpsFactor)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: pixelW,
                AVVideoHeightKey: pixelH,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: targetBitrate,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]

            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: pixelW,
                    kCVPixelBufferHeightKey as String: pixelH
                ]
            )

            guard writer.canAdd(vInput) else { return }
            writer.add(vInput)

            var sInput: AVAssetWriterInput?
            if captureSystemAudio {
                let sysSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000
                ]
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: sysSettings)
                ai.expectsMediaDataInRealTime = true
                if writer.canAdd(ai) {
                    writer.add(ai)
                    sInput = ai
                }
            }

            var mInput: AVAssetWriterInput?
            var captureSession: AVCaptureSession?
            if captureMic && micAllowed, let micDevice = AVCaptureDevice.default(for: .audio) {
                let session = AVCaptureSession()
                let deviceInput = try AVCaptureDeviceInput(device: micDevice)
                let audioOut = AVCaptureAudioDataOutput()
                audioOut.setSampleBufferDelegate(self, queue: mediaQueue)

                if session.canAddInput(deviceInput) && session.canAddOutput(audioOut) {
                    session.addInput(deviceInput)
                    session.addOutput(audioOut)

                    var sampleRate: Double = 48000
                    var channels: Int = 1
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(micDevice.activeFormat.formatDescription)?.pointee {
                        if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
                        if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
                    }

                    let micSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: channels,
                        AVEncoderBitRateKey: 96000
                    ]
                    let mi = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
                    mi.expectsMediaDataInRealTime = true
                    if writer.canAdd(mi) {
                        writer.add(mi)
                        mInput = mi
                        captureSession = session
                    }
                }
            }

            mediaQueue.sync {
                self.assetWriter = writer
                self.videoInput = vInput
                self.sysAudioInput = sInput
                self.micAudioInput = mInput
                self.pixelBufferAdaptor = adaptor
                self.sessionStarted = false
                self.pauseStartPTS = nil
                self.totalPausedDuration = .zero
            }

            let hasMicInput = (mInput != nil)
            let (hud, hudWindowID) = await MainActor.run { () -> (RecordingHUDWindow, CGWindowID) in
                let w = RecordingHUDWindow(visibleFrame: visibleFrame)
                w.configureMic(enabled: hasMicInput)
                w.onPauseToggle = { [weak self] in self?.togglePause() }
                w.onStop = { [weak self] in self?.stopRecording() }
                self.activeHUD = w
                return (w, CGWindowID(w.windowNumber))
            }

            let excludedWindows: [SCWindow] = content.windows.filter { $0.windowID == hudWindowID }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: mediaQueue)
            if captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: mediaQueue)
            }
            try await stream.startCapture()

            if let session = captureSession {
                self.micSession = session
                session.startRunning()
            }

            self.stream = stream
            self.isRecording = true
            self.isPaused = false
            self.accumulatedSeconds = 0
            self.segmentStartDate = Date()

            await MainActor.run {
                self.hudWindow = hud
                hud.makeKeyAndOrderFront(nil)
                NSSound(named: "Tink")?.play()
                self.updateUIState()

                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    self?.updateUIState()
                }
            }
        } catch {
            // Корректно откатываем ресурсы при сбое на любом этапе запуска
            self.micSession?.stopRunning(); self.micSession = nil
            mediaQueue.async {
                self.assetWriter?.cancelWriting()
                self.assetWriter = nil
                self.videoInput = nil
                self.sysAudioInput = nil
                self.micAudioInput = nil
                self.pixelBufferAdaptor = nil
                self.sessionStarted = false
            }

            await MainActor.run {
                self.isRecording = false
                self.isPaused = false
                self.hudWindow?.close()
                self.hudWindow = nil
                self.onRecordingStateChanged?(false, false, "")
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Не удалось начать запись"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    // Обработка внезапной остановки потока системой (например, отключение монитора)
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.stopRecording()
        }
    }

    // 4a. Обработка видео и системного звука из SCStream
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording, sampleBuffer.isValid else { return }

        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else { return }

            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if isPaused {
                if pauseStartPTS == nil { pauseStartPTS = rawPTS }
                return
            } else if let pauseStart = pauseStartPTS {
                let delta = CMTimeSubtract(rawPTS, pauseStart)
                if CMTimeCompare(delta, .zero) > 0 {
                    totalPausedDuration = CMTimeAdd(totalPausedDuration, delta)
                }
                pauseStartPTS = nil
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let writer = assetWriter,
                  let input = videoInput,
                  let adaptor = pixelBufferAdaptor else { return }

            let adjustedPTS = CMTimeSubtract(rawPTS, totalPausedDuration)

            if !sessionStarted && writer.status == .unknown {
                writer.startWriting()
                writer.startSession(atSourceTime: adjustedPTS)
                sessionStarted = true
            }

            if sessionStarted && writer.status == .writing && input.isReadyForMoreMediaData {
                adaptor.append(pixelBuffer, withPresentationTime: adjustedPTS)
            }
        } else if type == .audio {
            guard !isPaused, sessionStarted,
                  let writer = assetWriter, writer.status == .writing,
                  let sInput = sysAudioInput, sInput.isReadyForMoreMediaData else { return }

            if CMTimeCompare(totalPausedDuration, .zero) == 0 {
                sInput.append(sampleBuffer)
            } else if let shifted = shiftSampleBufferPTS(sampleBuffer, by: totalPausedDuration) {
                sInput.append(shifted)
            }
        }
    }

    // 4b. Обработка звука микрофона с привязкой к общим часам HostTimeClock
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, !isPaused, sessionStarted, sampleBuffer.isValid,
              let writer = assetWriter, writer.status == .writing,
              let mInput = micAudioInput, mInput.isReadyForMoreMediaData else { return }

        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let targetPTS = CMTimeSubtract(hostNow, totalPausedDuration)
        if let synced = retimeSampleBuffer(sampleBuffer, newPTS: targetPTS) {
            mInput.append(synced)
        }

        var hasVoice = false
        if let block = CMSampleBufferGetDataBuffer(sampleBuffer),
           let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
               let p = ptr, len >= 4 {
                let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                if isFloat {
                    let count = len / 4
                    let peak: Float = p.withMemoryRebound(to: Float.self, capacity: count) { buf in
                        var m: Float = 0
                        for i in stride(from: 0, to: count, by: max(1, count / 64)) { m = max(m, abs(buf[i])) }
                        return m
                    }
                    hasVoice = peak > 0.015
                } else {
                    let count = len / 2
                    let peak: Int32 = p.withMemoryRebound(to: Int16.self, capacity: count) { buf in
                        var m: Int32 = 0
                        for i in stride(from: 0, to: count, by: max(1, count / 64)) { m = max(m, abs(Int32(buf[i]))) }
                        return m
                    }
                    hasVoice = peak > 350
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.activeHUD?.notifyMicSignal(active: hasVoice)
        }
    }

    private func retimeSampleBuffer(_ sampleBuffer: CMSampleBuffer, newPTS: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &count)
        for i in 0..<count {
            timingInfo[i].presentationTimeStamp = newPTS
            timingInfo[i].decodeTimeStamp = .invalid
        }
        var outBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count, sampleTimingArray: &timingInfo, sampleBufferOut: &outBuffer)
        return outBuffer
    }

    private func shiftSampleBufferPTS(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &count)
        for i in 0..<count {
            timingInfo[i].presentationTimeStamp = CMTimeSubtract(timingInfo[i].presentationTimeStamp, offset)
            if timingInfo[i].decodeTimeStamp.isValid {
                timingInfo[i].decodeTimeStamp = CMTimeSubtract(timingInfo[i].decodeTimeStamp, offset)
            }
        }
        var outBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count, sampleTimingArray: &timingInfo, sampleBufferOut: &outBuffer)
        return outBuffer
    }

    // 5. Безопасная остановка и сохранение MP4 без гонки очередей
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        timer?.invalidate()
        timer = nil

        hudWindow?.orderOut(nil)
        hudWindow = nil

        let activeStream = stream
        let activeMic = micSession
        let savedURL = outputURL
        stream = nil
        micSession = nil

        activeMic?.stopRunning()

        Task {
            try? await activeStream?.stopCapture()

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.mediaQueue.async {
                    let writer = self.assetWriter
                    let vIn = self.videoInput
                    let sIn = self.sysAudioInput
                    let mIn = self.micAudioInput
                    let started = self.sessionStarted

                    self.assetWriter = nil
                    self.videoInput = nil
                    self.sysAudioInput = nil
                    self.micAudioInput = nil
                    self.pixelBufferAdaptor = nil
                    self.sessionStarted = false

                    guard started, let w = writer, w.status == .writing else {
                        writer?.cancelWriting()
                        continuation.resume()
                        return
                    }

                    vIn?.markAsFinished()
                    sIn?.markAsFinished()
                    mIn?.markAsFinished()

                    w.finishWriting {
                        continuation.resume()
                    }
                }
            }

            await MainActor.run {
                self.onRecordingStateChanged?(false, false, "")
                NSSound(named: "Glass")?.play()
                if let url = savedURL, FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}

// MARK: - Плавающая панель управления записью (Таймер + Пауза + Стоп)
private final class RecordingHUDWindow: NSPanel {
    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?

    private let dotView = NSView()
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let micIconView = NSImageView()
    private var pauseBtn: PillButton!
    private var stopBtn: PillButton!
    private var micEnabled = false
    private var lastMicPulse: CFTimeInterval = 0

    func configureMic(enabled: Bool) {
        self.micEnabled = enabled
        let sym = enabled ? "mic.fill" : "mic.slash.fill"
        micIconView.image = NSImage(systemSymbolName: sym, accessibilityDescription: "Mic")
        micIconView.contentTintColor = enabled ? NSColor.white.withAlphaComponent(0.6) : NSColor.systemGray.withAlphaComponent(0.45)
        micIconView.toolTip = enabled ? "Микрофон включён (зелёный при наличии звука)" : "Микрофон выключен или нет доступа"
    }

    func notifyMicSignal(active: Bool) {
        guard micEnabled else { return }
        let now = CACurrentMediaTime()
        if active {
            lastMicPulse = now
            micIconView.contentTintColor = NSColor.systemGreen
        } else if now - lastMicPulse > 0.35 {
            micIconView.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        }
    }

    init(visibleFrame: CGRect) {
        let width: CGFloat = 238
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

        micIconView.frame = NSRect(x: 88, y: (height - 16) / 2, width: 16, height: 16)
        micIconView.imageScaling = .scaleProportionallyDown
        root.addSubview(micIconView)
        configureMic(enabled: false)

        pauseBtn = PillButton(
            frame: NSRect(x: 112, y: 8, width: 34, height: 30),
            title: nil,
            symbolName: "pause.fill",
            cornerRadius: 15
        ) { [weak self] in
            self?.onPauseToggle?()
        }
        pauseBtn.toolTip = "Пауза / Продолжить"
        root.addSubview(pauseBtn)

        stopBtn = PillButton(
            frame: NSRect(x: 152, y: 8, width: 74, height: 30),
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

        if let iv = pauseBtn.subviews.compactMap({ $0 as? NSImageView }).first,
           let sym = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil) {
            iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        }
    }
}

// MARK: - Полноэкранный оверлей выбора области
private final class RegionSelectionWindow: NSWindow {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false

        let view = SelectionCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { [weak self] localRect in
            guard let self = self else { return }
            let screenRect = CGRect(
                x: screen.frame.origin.x + localRect.origin.x,
                y: screen.frame.origin.y + localRect.origin.y,
                width: localRect.width,
                height: localRect.height
            )
            self.orderOut(nil)
            self.onRegionSelected?(screenRect)
        }
        view.onCancel = { [weak self] in
            self?.orderOut(nil)
            self?.onCancelled?()
        }
        self.contentView = view
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionCanvasView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let p1 = startPoint, let p2 = currentPoint else { return }
        let rect = NSRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )
        onComplete?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()

        guard let p1 = startPoint, let p2 = currentPoint else { return }
        let rect = NSRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )

        NSGraphicsContext.current?.compositingOperation = .clear
        rect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.systemGreen.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2.0
        border.stroke()

        let badgeText = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = badgeText.size(withAttributes: attrs)
        let badgeRect = NSRect(x: rect.minX, y: max(8, rect.minY - size.height - 10), width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
        badgeText.draw(at: NSPoint(x: badgeRect.minX + 7, y: badgeRect.minY + 3), withAttributes: attrs)
    }
}
