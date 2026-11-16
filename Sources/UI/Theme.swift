import Cocoa

extension Notification.Name {
    static let quickSnapThemeChanged = Notification.Name("QuickSnapThemeChanged")
}

extension NSTextField {
    static func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .white
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.drawsBackground = false
        label.isBezeled = false
        return label
    }
}

enum AppThemeStyle: String, CaseIterable {
    case native = "native"
    case glass = "glass"
    case classic = "classic"

    var title: String {
        switch self {
        case .native: return "Нативный"
        case .glass: return "Стекло"
        case .classic: return "Классика"
        }
    }
}

struct ThemeTokens {
    let style: AppThemeStyle

    var isClassic: Bool { style == .classic }
    var isNative: Bool { style == .native }
    var isGlass: Bool { style == .glass }
    var useBlurMaterial: Bool { style != .classic }

    // Поповер
    var popoverMaterial: NSVisualEffectView.Material {
        switch style {
        case .native: return .hudWindow
        case .glass: return .popover
        case .classic: return .underWindowBackground
        }
    }

    var solidBackgroundColor: NSColor {
        NSColor(calibratedRed: 0.071, green: 0.071, blue: 0.082, alpha: 1.0) // #121215 (глубокий чёрный)
    }

    var tintOverlayColor: CGColor {
        switch style {
        case .native:
            return NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.72).cgColor
        case .glass:
            return NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.22, alpha: 0.34).cgColor
        case .classic:
            return solidBackgroundColor.cgColor
        }
    }

    var windowBorderColor: CGColor? {
        switch style {
        case .native: return NSColor.white.withAlphaComponent(0.16).cgColor
        case .glass: return NSColor.white.withAlphaComponent(0.28).cgColor
        case .classic: return NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    // Карточки действий
    var cardBackgroundColor: CGColor {
        switch style {
        case .native: return NSColor.white.withAlphaComponent(0.07).cgColor
        case .glass: return NSColor.white.withAlphaComponent(0.14).cgColor
        case .classic: return NSColor.clear.cgColor
        }
    }

    var cardHoverBackgroundColor: CGColor {
        switch style {
        case .native: return NSColor.white.withAlphaComponent(0.13).cgColor
        case .glass: return NSColor.white.withAlphaComponent(0.22).cgColor
        case .classic: return NSColor.clear.cgColor
        }
    }

    var cardBorderColor: CGColor {
        switch style {
        case .native: return NSColor.white.withAlphaComponent(0.10).cgColor
        case .glass: return NSColor.white.withAlphaComponent(0.26).cgColor
        case .classic: return NSColor.clear.cgColor
        }
    }

    // Цвета иконок
    var areaAccent: NSColor {
        switch style {
        case .native: return NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.24, alpha: 1.0)
        case .glass: return NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.25, alpha: 1.0)
        case .classic: return NSColor(calibratedRed: 0.88, green: 0.95, blue: 0.18, alpha: 1.0)
        }
    }

    var windowAccent: NSColor {
        switch style {
        case .native: return NSColor(calibratedRed: 0.34, green: 0.76, blue: 0.98, alpha: 1.0)
        case .glass: return NSColor(calibratedRed: 0.38, green: 0.85, blue: 1.0, alpha: 1.0)
        case .classic: return NSColor(calibratedRed: 0.22, green: 0.88, blue: 0.98, alpha: 1.0)
        }
    }

    var videoAccent: NSColor {
        switch style {
        case .native: return NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.58, alpha: 1.0)
        case .glass: return NSColor(calibratedRed: 0.24, green: 0.94, blue: 0.62, alpha: 1.0)
        case .classic: return NSColor(calibratedRed: 0.34, green: 0.92, blue: 0.60, alpha: 1.0)
        }
    }

    // Окно настроек
    var settingsSidebarBg: CGColor {
        switch style {
        case .native: return NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0).cgColor
        case .glass: return NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.19, alpha: 1.0).cgColor
        case .classic: return NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.065, alpha: 1.0).cgColor // #0E0E10
        }
    }

    var settingsContentBg: CGColor {
        switch style {
        case .native: return NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.19, alpha: 1.0).cgColor
        case .glass: return NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.24, alpha: 1.0).cgColor
        case .classic: return NSColor(calibratedRed: 0.082, green: 0.082, blue: 0.094, alpha: 1.0).cgColor // #151518
        }
    }

    var settingsAccent: NSColor {
        switch style {
        case .native: return NSColor(calibratedRed: 0.24, green: 0.45, blue: 0.78, alpha: 1.0)
        case .glass: return NSColor(calibratedRed: 0.27, green: 0.50, blue: 0.84, alpha: 0.88)
        case .classic: return NSColor(calibratedRed: 0.22, green: 0.46, blue: 0.82, alpha: 1.0)
        }
    }

    var iconCircleBackground: Bool { isClassic }
    var cropThumbnailsToFill: Bool { !isClassic }
    var showPowerButtonInFooter: Bool { isClassic || isGlass }
    var showFpsInVideoShortcut: Bool { isClassic }
}
