import Foundation
import CoreGraphics
import CoreMedia

enum VideoCaptureMath {
    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    /// Округляет размеры до чётных пикселей (требование H.264/HEVC энкодеров)
    static func evenPixelSize(for rect: CGRect, scale: CGFloat) -> (width: Int, height: Int)? {
        let pixelW = (Int(rect.width * scale) / 2) * 2
        let pixelH = (Int(rect.height * scale) / 2) * 2
        guard pixelW >= 32, pixelH >= 32 else { return nil }
        return (pixelW, pixelH)
    }

    /// Переводит координаты AppKit (ось Y снизу вверх) в координаты ScreenCaptureKit (ось Y сверху вниз)
    static func makeSourceRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        let flippedY = screenFrame.height - (selection.origin.y - screenFrame.origin.y) - selection.height
        return CGRect(
            x: selection.origin.x - screenFrame.origin.x,
            y: flippedY,
            width: selection.width,
            height: selection.height
        )
    }

    /// Вычисляет целевой битрейт в зависимости от разрешения и FPS
    static func targetBitrate(pixelWidth: Int, pixelHeight: Int, fps: Int) -> Int {
        let fpsFactor = (fps == 30) ? 9 : 15
        let floorBitrate = (fps == 30) ? 7_000_000 : 12_000_000
        return max(floorBitrate, pixelWidth * pixelHeight * fpsFactor)
    }

    /// Форматирует длительность записи в MM:SS
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let sec = max(0, Int(seconds))
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }

    /// Вычитает накопленную паузу из исходного PTS
    static func adjustedPTS(rawPTS: CMTime, pausedOffset: CMTime) -> CMTime {
        CMTimeSubtract(rawPTS, pausedOffset)
    }

    /// Генерирует имя выходного файла с защитой от коллизий в пределах одной секунды
    static func makeOutputFilename(
        prefix: String = "QuickSnap",
        ext: String = "mp4",
        date: Date = Date(),
        timeZone: TimeZone = .current,
        existingNames: Set<String> = []
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let stamp = formatter.string(from: date)
        let baseName = "\(prefix)_\(stamp).\(ext)"
        if !existingNames.contains(baseName) {
            return baseName
        }

        var suffix = 2
        while true {
            let candidate = "\(prefix)_\(stamp)_\(suffix).\(ext)"
            if !existingNames.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    /// Нормализует значение FPS из Config (поддерживаются только 30 и 60, по умолчанию 60)
    static func normalizeFPS(_ rawFPS: Int) -> Int {
        rawFPS == 30 ? 30 : 60
    }

    /// Парсит строковое значение темы из UserDefaults с фолбэком на "native"
    static func parseThemeRawValue(_ raw: String?) -> String {
        let allowed: Set<String> = ["native", "glass", "classic"]
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              allowed.contains(value) else {
            return "native"
        }
        return value
    }

    /// Проверяет и нормализует путь сохранения из Config
    static func resolveSaveDirectory(storedPath: String?, fallback: URL) -> URL {
        guard let raw = storedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return fallback
        }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
