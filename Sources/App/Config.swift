import Cocoa
import Carbon

struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultArea = KeyShortcut(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(optionKey))
    static let defaultWindow = KeyShortcut(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(optionKey))
    static let defaultVideo = KeyShortcut(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(optionKey))

    var displayString: String {
        var parts: [String] = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        if (carbonModifiers & UInt32(optionKey)) != 0 { parts.append("⌥") }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { parts.append("⇧") }
        if (carbonModifiers & UInt32(cmdKey)) != 0 { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined(separator: " ")
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    private static let keyCodeMap: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"
    ]

    static func keyName(for code: UInt32) -> String {
        return keyCodeMap[Int(code)] ?? "#\(code)"
    }
}

// MARK: - Настройки приложения, темы, видео и горячих клавиш
struct Config {
    private static let dirKey = "QuickSnapSaveDirectory"
    private static let themeStyleKey = "QuickSnapThemeStyle"
    private static let videoFpsKey = "QuickSnapVideoFPS"
    private static let videoCursorKey = "QuickSnapVideoShowCursor"
    private static let videoAskAudioKey = "QuickSnapVideoAskAudio"
    private static let videoSysAudioKey = "QuickSnapVideoSystemAudio"
    private static let videoMicAudioKey = "QuickSnapVideoMicAudio"

    private static let areaHotkeyKey = "QuickSnapHotkeyArea"
    private static let windowHotkeyKey = "QuickSnapHotkeyWindow"
    private static let videoHotkeyKey = "QuickSnapHotkeyVideo"

    // Дефолт теперь: Нативный macOS (.native)
    static var themeStyle: AppThemeStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: themeStyleKey),
                  let style = AppThemeStyle(rawValue: raw) else {
                return .native
            }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeStyleKey)
            NotificationCenter.default.post(name: .quickSnapThemeChanged, object: nil)
        }
    }

    static var tokens: ThemeTokens {
        ThemeTokens(style: themeStyle)
    }

    static let defaultDirectory: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        return desktop.appendingPathComponent("Screenshots", isDirectory: true)
    }()

    static var hasConfiguredDirectory: Bool {
        guard let saved = UserDefaults.standard.string(forKey: dirKey) else { return false }
        return !saved.isEmpty
    }

    static var saveDirectory: URL {
        get {
            if let savedPath = UserDefaults.standard.string(forKey: dirKey), !savedPath.isEmpty {
                return URL(fileURLWithPath: savedPath, isDirectory: true)
            }
            return defaultDirectory
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: dirKey)
            try? FileManager.default.createDirectory(at: newValue, withIntermediateDirectories: true)
            ScreenshotWatcher.shared.startWatching()
        }
    }

    static var videoFPS: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: videoFpsKey)
            return (val == 30 || val == 60) ? val : 60
        }
        set { UserDefaults.standard.set(newValue, forKey: videoFpsKey) }
    }

    static var videoShowCursor: Bool {
        get { UserDefaults.standard.object(forKey: videoCursorKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: videoCursorKey) }
    }

    static var videoAskAudioBeforeRecord: Bool {
        get { UserDefaults.standard.object(forKey: videoAskAudioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: videoAskAudioKey) }
    }

    static var videoCaptureSystemAudio: Bool {
        get { UserDefaults.standard.object(forKey: videoSysAudioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: videoSysAudioKey) }
    }

    static var videoCaptureMicrophone: Bool {
        get { UserDefaults.standard.object(forKey: videoMicAudioKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: videoMicAudioKey) }
    }

    static var areaShortcut: KeyShortcut {
        get { loadShortcut(key: areaHotkeyKey, fallback: .defaultArea) }
        set { saveShortcut(newValue, key: areaHotkeyKey) }
    }

    static var windowShortcut: KeyShortcut {
        get { loadShortcut(key: windowHotkeyKey, fallback: .defaultWindow) }
        set { saveShortcut(newValue, key: windowHotkeyKey) }
    }

    static var videoShortcut: KeyShortcut {
        get { loadShortcut(key: videoHotkeyKey, fallback: .defaultVideo) }
        set { saveShortcut(newValue, key: videoHotkeyKey) }
    }

    static func resetShortcutsToDefaults() {
        UserDefaults.standard.removeObject(forKey: areaHotkeyKey)
        UserDefaults.standard.removeObject(forKey: windowHotkeyKey)
        UserDefaults.standard.removeObject(forKey: videoHotkeyKey)
        HotKeyManager.shared.registerDefaults()
    }

    private static func loadShortcut(key: String, fallback: KeyShortcut) -> KeyShortcut {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(KeyShortcut.self, from: data) else {
            return fallback
        }
        return decoded
    }

    private static func saveShortcut(_ shortcut: KeyShortcut, key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        }
        HotKeyManager.shared.registerDefaults()
    }

    static func ensureInitialDirectorySetup() {
        guard !hasConfiguredDirectory else {
            try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Папка для сохранения снимков"
        alert.informativeText = "Создать папку «Screenshots» на Рабочем столе или выбрать другую директорию?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Создать Desktop/Screenshots")
        alert.addButton(withTitle: "Выбрать другую…")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let panel = NSOpenPanel()
            panel.title = "Выберите папку для сохранения"
            panel.prompt = "Выбрать"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

            if panel.runModal() == .OK, let chosen = panel.url {
                saveDirectory = chosen
                return
            }
        }

        saveDirectory = defaultDirectory
    }
}
