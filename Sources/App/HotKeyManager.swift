import Cocoa
import Carbon

// MARK: - Глобальные горячие клавиши (Carbon RegisterEventHotKey)
final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private let signature: OSType = 0x51534E50 // 'QSNP'

    deinit {
        unregisterAll()
    }

    func registerDefaults() {
        unregisterAll()

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                let keyID = hotKeyID.id
                DispatchQueue.main.async {
                    manager.handleHotKey(id: keyID)
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )

        let area = Config.areaShortcut
        let win = Config.windowShortcut
        let video = Config.videoShortcut

        registerKey(id: 1, keyCode: area.keyCode, modifiers: area.carbonModifiers)
        registerKey(id: 2, keyCode: win.keyCode, modifiers: win.carbonModifiers)
        registerKey(id: 3, keyCode: video.keyCode, modifiers: video.carbonModifiers)
    }

    private func registerKey(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let r = ref {
            hotKeyRefs.append(r)
        }
    }

    private func handleHotKey(id: UInt32) {
        switch id {
        case 1:
            ScreenCaptureManager.shared.capture(windowMode: false)
        case 2:
            ScreenCaptureManager.shared.capture(windowMode: true)
        case 3:
            if #available(macOS 13.0, *) {
                ScreenRecorderManager.shared.toggleRecordingFlow()
            }
        default:
            break
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
