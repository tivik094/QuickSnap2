import Cocoa
import CoreGraphics

final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    private init() {}

    static func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // Нативный системный запрос macOS — сам регистрирует приложение в разделе Запись экрана
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Нужен доступ к записи экрана"
            alert.informativeText = "Откройте Системные настройки → Конфиденциальность и безопасность → Запись экрана и включите переключатель напротив QuickSnap 2.0."
            alert.addButton(withTitle: "Понятно")
            _ = alert.runModal()
        }
        return false
    }

    func capture(windowMode: Bool) {
        guard Self.ensureScreenCapturePermission() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "QuickSnap_\(formatter.string(from: Date())).png"
            let targetURL = Config.saveDirectory.appendingPathComponent(filename)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = windowMode ? ["-iw", targetURL.path] : ["-i", targetURL.path]
            try? task.run()
        }
    }
}
