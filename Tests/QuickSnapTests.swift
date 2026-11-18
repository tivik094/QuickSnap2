import Foundation
import CoreGraphics
import CoreMedia

@main
struct QuickSnapTestRunner {
    static var passed = 0
    static var failed = 0

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
        if actual == expected {
            passed += 1
        } else {
            failed += 1
            print("❌ [FAIL] \(name) (строка \(line)): получено \(actual), ожидалось \(expected)")
        }
    }

    static func assertNil<T>(_ actual: T?, _ name: String, line: Int = #line) {
        if actual == nil {
            passed += 1
        } else {
            failed += 1
            print("❌ [FAIL] \(name) (строка \(line)): ожидалось nil, получено \(String(describing: actual))")
        }
    }

    static func main() {
        testEvenPixelSize()
        testSourceRectCoordinateFlip()
        testMultiMonitorSourceRect()
        testBitrateCalculation()
        testDurationFormatting()
        testPausedPTSShift()
        testOutputFilenameGeneration()
        testOutputFilenameCollisionSuffix()
        testConfigParsing()
        testIsolatedUserDefaultsConfigRoundtrip()

        print("\n📊 Итого: \(passed) прошло, \(failed) упало")
        if failed > 0 { exit(1) }
    }

    static func testEvenPixelSize() {
        let size = VideoCaptureMath.evenPixelSize(for: CGRect(x: 0, y: 0, width: 100.5, height: 50.5), scale: 2.0)
        assertEqual(size?.width, 200, "evenPixelSize width (Retina 2x)")
        assertEqual(size?.height, 100, "evenPixelSize height (Retina 2x)")

        let tooSmall = VideoCaptureMath.evenPixelSize(for: CGRect(x: 0, y: 0, width: 15, height: 15), scale: 2.0)
        assertNil(tooSmall, "evenPixelSize rejects < 32px")
    }

    static func testSourceRectCoordinateFlip() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 100, y: 880, width: 300, height: 200)
        let result = VideoCaptureMath.makeSourceRect(selection: selection, screenFrame: screen)

        assertEqual(result, CGRect(x: 100, y: 0, width: 300, height: 200), "AppKit top-left -> SCStream y=0")
    }

    static func testMultiMonitorSourceRect() {
        let secondScreen = CGRect(x: 1920, y: 100, width: 1440, height: 900)
        let selection = CGRect(x: 2020, y: 200, width: 400, height: 300)
        let result = VideoCaptureMath.makeSourceRect(selection: selection, screenFrame: secondScreen)

        assertEqual(result, CGRect(x: 100, y: 500, width: 400, height: 300), "Multi-monitor offset & Y flip")
    }

    static func testBitrateCalculation() {
        assertEqual(VideoCaptureMath.targetBitrate(pixelWidth: 400, pixelHeight: 300, fps: 30), 7_000_000, "Min bitrate 30fps")
        assertEqual(VideoCaptureMath.targetBitrate(pixelWidth: 400, pixelHeight: 300, fps: 60), 12_000_000, "Min bitrate 60fps")
        assertEqual(VideoCaptureMath.targetBitrate(pixelWidth: 3840, pixelHeight: 2160, fps: 60), 124_416_000, "4K 60fps bitrate")
    }

    static func testDurationFormatting() {
        assertEqual(VideoCaptureMath.formatDuration(0), "00:00", "Format 0s")
        assertEqual(VideoCaptureMath.formatDuration(65.9), "01:05", "Format 65.9s")
        assertEqual(VideoCaptureMath.formatDuration(-5), "00:00", "Format negative clamped")
    }

    static func testPausedPTSShift() {
        let raw = CMTime(value: 1000, timescale: 100)
        let paused = CMTime(value: 350, timescale: 100)
        let adjusted = VideoCaptureMath.adjustedPTS(rawPTS: raw, pausedOffset: paused)
        assertEqual(CMTimeCompare(adjusted, CMTime(value: 650, timescale: 100)), 0, "Adjusted PTS after pause")
    }

    static func testOutputFilenameGeneration() {
        // Фиксированная дата: 2026-11-18 14:05:09 UTC
        let date = Date(timeIntervalSince1970: 1795010709)
        let utc = TimeZone(secondsFromGMT: 0)!

        let mp4Name = VideoCaptureMath.makeOutputFilename(date: date, timeZone: utc)
        assertEqual(mp4Name, "QuickSnap_2026-11-18_14-05-09.mp4", "Default MP4 filename")

        let pngName = VideoCaptureMath.makeOutputFilename(prefix: "Shot", ext: "png", date: date, timeZone: utc)
        assertEqual(pngName, "Shot_2026-11-18_14-05-09.png", "Custom prefix & ext filename")
    }

    static func testOutputFilenameCollisionSuffix() {
        let date = Date(timeIntervalSince1970: 1795010709)
        let utc = TimeZone(secondsFromGMT: 0)!
        let existing: Set<String> = [
            "QuickSnap_2026-11-18_14-05-09.mp4",
            "QuickSnap_2026-11-18_14-05-09_2.mp4"
        ]

        let nextName = VideoCaptureMath.makeOutputFilename(date: date, timeZone: utc, existingNames: existing)
        assertEqual(nextName, "QuickSnap_2026-11-18_14-05-09_3.mp4", "Collision suffix increments to _3")
    }

    static func testConfigParsing() {
        // FPS
        assertEqual(VideoCaptureMath.normalizeFPS(30), 30, "Valid 30 FPS")
        assertEqual(VideoCaptureMath.normalizeFPS(60), 60, "Valid 60 FPS")
        assertEqual(VideoCaptureMath.normalizeFPS(0), 60, "Invalid 0 FPS -> fallback 60")
        assertEqual(VideoCaptureMath.normalizeFPS(144), 60, "Unsupported 144 FPS -> fallback 60")

        // Тема
        assertEqual(VideoCaptureMath.parseThemeRawValue("glass"), "glass", "Theme glass")
        assertEqual(VideoCaptureMath.parseThemeRawValue(" CLASSIC "), "classic", "Theme classic trimmed & lowercased")
        assertEqual(VideoCaptureMath.parseThemeRawValue("neon"), "native", "Unknown theme -> fallback native")
        assertEqual(VideoCaptureMath.parseThemeRawValue(nil), "native", "Nil theme -> fallback native")

        // Путь сохранения
        let fallback = URL(fileURLWithPath: "/tmp/DefaultQuickSnap", isDirectory: true)
        assertEqual(VideoCaptureMath.resolveSaveDirectory(storedPath: nil, fallback: fallback), fallback, "Nil path -> fallback")
        assertEqual(VideoCaptureMath.resolveSaveDirectory(storedPath: "   ", fallback: fallback), fallback, "Empty path -> fallback")

        let resolvedCustom = VideoCaptureMath.resolveSaveDirectory(storedPath: "/Users/test/Captures", fallback: fallback)
        assertEqual(resolvedCustom.path, "/Users/test/Captures", "Custom path preserved")
    }

    static func testIsolatedUserDefaultsConfigRoundtrip() {
        let suiteName = "com.viktor.quicksnap2.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            failed += 1
            print("❌ [FAIL] Не удалось создать изолированный UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Проверяем чтение дефолтов из пустого хранилища
        let initialFPS = VideoCaptureMath.normalizeFPS(defaults.integer(forKey: "videoFPS"))
        let initialTheme = VideoCaptureMath.parseThemeRawValue(defaults.string(forKey: "themeStyle"))
        assertEqual(initialFPS, 60, "Empty UserDefaults -> 60 FPS")
        assertEqual(initialTheme, "native", "Empty UserDefaults -> native theme")

        // Записываем и читаем обратно
        defaults.set(30, forKey: "videoFPS")
        defaults.set("glass", forKey: "themeStyle")
        defaults.set("/tmp/MyShots", forKey: "saveDirectory")

        let fallback = URL(fileURLWithPath: "/tmp/Fallback")
        assertEqual(VideoCaptureMath.normalizeFPS(defaults.integer(forKey: "videoFPS")), 30, "Roundtrip 30 FPS")
        assertEqual(VideoCaptureMath.parseThemeRawValue(defaults.string(forKey: "themeStyle")), "glass", "Roundtrip glass theme")
        assertEqual(
            VideoCaptureMath.resolveSaveDirectory(storedPath: defaults.string(forKey: "saveDirectory"), fallback: fallback).path,
            "/tmp/MyShots",
            "Roundtrip saveDirectory"
        )
    }
}
