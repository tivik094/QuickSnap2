import Cocoa
import CoreGraphics

final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    private init() {}

    // Кэшируем DateFormatter, так как его создание — дорогая операция
    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    static func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
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
            Config.ensureInitialDirectorySetup()
            let filename = "QuickSnap_\(Self.fileDateFormatter.string(from: Date())).png"
            let targetURL = Config.saveDirectory.appendingPathComponent(filename)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = windowMode ? ["-iw", targetURL.path] : ["-i", targetURL.path]

            // Очищаем ресурсы процесса после завершения, чтобы не копить зомби-процессы
            task.terminationHandler = { _ in }

            do {
                try task.run()
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Ошибка захвата экрана"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}
