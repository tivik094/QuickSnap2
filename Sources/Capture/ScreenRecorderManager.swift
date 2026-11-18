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
    private var _isStarting = false
    private var _isPaused = false
    private var _isMicMuted = false
    private var _pauseStartHostTime: CMTime?
    private var _totalPausedDuration: CMTime = .zero

    private(set) var isRecording: Bool {
        get { stateLock.withLock { _isRecording } }
        set { stateLock.withLock { _isRecording = newValue } }
    }

    private(set) var isPaused: Bool {
        get { stateLock.withLock { _isPaused } }
        set { stateLock.withLock { _isPaused = newValue } }
    }

    private(set) var isMicMuted: Bool {
        get { stateLock.withLock { _isMicMuted } }
        set { stateLock.withLock { _isMicMuted = newValue } }
    }

    private var sessionStarted = false
    private var accumulatedSeconds: TimeInterval = 0
    private var segmentStartDate: Date?

    private var timer: Timer?
    private var selectionWindow: RegionSelectionWindow?
    private var hudWindow: RecordingHUDWindow?
    private var borderWindow: RecordingBorderWindow?

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
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let pausedNow: Bool = stateLock.withLock {
            if _isPaused {
                _isPaused = false
                if let pauseStart = _pauseStartHostTime {
                    let delta = CMTimeSubtract(now, pauseStart)
                    if CMTimeCompare(delta, .zero) > 0 {
                        _totalPausedDuration = CMTimeAdd(_totalPausedDuration, delta)
                    }
                    _pauseStartHostTime = nil
                }
                segmentStartDate = Date()
                return false
            } else {
                _isPaused = true
                _pauseStartHostTime = now
                if let start = segmentStartDate {
                    accumulatedSeconds += Date().timeIntervalSince(start)
                    segmentStartDate = nil
                }
                return true
            }
        }
        NSSound(named: pausedNow ? "Pop" : "Tink")?.play()
        updateUIState()
    }

    func toggleMicMute() {
        guard isRecording, micSession != nil else { return }
        let newMuted = !isMicMuted
        isMicMuted = newMuted
        NSSound(named: newMuted ? "Pop" : "Tink")?.play()
        if Thread.isMainThread {
            hudWindow?.setMicMuted(newMuted)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.hudWindow?.setMicMuted(newMuted)
            }
        }
    }

    private func currentFormattedTime() -> String {
        let total: TimeInterval = stateLock.withLock {
            var t = accumulatedSeconds
            if !_isPaused, let start = segmentStartDate {
                t += Date().timeIntervalSince(start)
            }
            return t
        }
        return VideoCaptureMath.formatDuration(total)
    }

    private func updateUIState() {
        let timeStr = currentFormattedTime()
        let rec = isRecording
        let paused = isPaused
        if Thread.isMainThread {
            hudWindow?.update(isPaused: paused, timeText: timeStr)
            borderWindow?.setPaused(paused)
            onRecordingStateChanged?(rec, paused, timeStr)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.hudWindow?.update(isPaused: paused, timeText: timeStr)
                self?.borderWindow?.setPaused(paused)
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
        let canStart = stateLock.withLock { () -> Bool in
            guard !_isRecording && !_isStarting else { return false }
            _isStarting = true
            return true
        }
        guard canStart else { return }

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

            guard let (pixelW, pixelH) = VideoCaptureMath.evenPixelSize(for: rect, scale: scale) else { return }
            let sourceRect = VideoCaptureMath.makeSourceRect(selection: rect, screenFrame: screenFrame)

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
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: Config.saveDirectory.path)) ?? []
            let filename = VideoCaptureMath.makeOutputFilename(existingNames: Set(existing))
            let url = Config.saveDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
            self.outputURL = url

            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let targetBitrate = VideoCaptureMath.targetBitrate(pixelWidth: pixelW, pixelHeight: pixelH, fps: fps)
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
            }
            self.stateLock.withLock {
                self._pauseStartHostTime = nil
                self._totalPausedDuration = .zero
            }

            self.isMicMuted = false
            let hasMicInput = (mInput != nil)
            let (hud, border, excludedIDs) = await MainActor.run { () -> (RecordingHUDWindow, RecordingBorderWindow, Set<CGWindowID>) in
                let w = RecordingHUDWindow(visibleFrame: visibleFrame)
                w.configureMic(enabled: hasMicInput)
                w.onMicToggle = { [weak self] in self?.toggleMicMute() }
                w.onPauseToggle = { [weak self] in self?.togglePause() }
                w.onStop = { [weak self] in self?.stopRecording() }
                self.activeHUD = w

                let b = RecordingBorderWindow(captureRect: rect)
                let ids: Set<CGWindowID> = [CGWindowID(w.windowNumber), CGWindowID(b.windowNumber)]
                return (w, b, ids)
            }

            let excludedWindows: [SCWindow] = content.windows.filter { excludedIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: mediaQueue)
            if captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: mediaQueue)
            }
            self.stream = stream
            self.micSession = captureSession
            stateLock.withLock {
                self._isRecording = true
                self._isStarting = false
                self._isPaused = false
                self.accumulatedSeconds = 0
                self.segmentStartDate = Date()
            }

            try await stream.startCapture()
            captureSession?.startRunning()

            await MainActor.run {
                self.hudWindow = hud
                self.borderWindow = border
                border.orderFrontRegardless()
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

            stateLock.withLock {
                self._isRecording = false
                self._isStarting = false
                self._isPaused = false
            }

            await MainActor.run {
                self.hudWindow?.close()
                self.hudWindow = nil
                self.borderWindow?.close()
                self.borderWindow = nil
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

            guard !isPaused else { return }
            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let writer = assetWriter,
                  let input = videoInput,
                  let adaptor = pixelBufferAdaptor else { return }

            let pausedOffset = stateLock.withLock { _totalPausedDuration }
            let adjustedPTS = CMTimeSubtract(rawPTS, pausedOffset)

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

            let pausedOffset = stateLock.withLock { _totalPausedDuration }
            if CMTimeCompare(pausedOffset, .zero) == 0 {
                sInput.append(sampleBuffer)
            } else if let shifted = shiftSampleBufferPTS(sampleBuffer, by: pausedOffset) {
                sInput.append(shifted)
            }
        }
    }

    // 4b. Обработка звука микрофона с привязкой к общим часам HostTimeClock
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, !isPaused, sessionStarted, sampleBuffer.isValid,
              let writer = assetWriter, writer.status == .writing,
              let mInput = micAudioInput, mInput.isReadyForMoreMediaData else { return }

        let (muted, pausedOffset) = stateLock.withLock { (_isMicMuted, _totalPausedDuration) }
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let targetPTS = CMTimeSubtract(hostNow, pausedOffset)
        if let synced = retimeSampleBuffer(sampleBuffer, newPTS: targetPTS) {
            if muted, let block = CMSampleBufferGetDataBuffer(synced) {
                let totalLen = CMBlockBufferGetDataLength(block)
                if totalLen > 0 {
                    CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: totalLen)
                }
            }
            if writer.status == .writing && mInput.isReadyForMoreMediaData {
                mInput.append(synced)
            }
        }

        if muted { return }

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
        borderWindow?.orderOut(nil)
        borderWindow = nil

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
