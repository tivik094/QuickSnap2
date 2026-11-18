import Cocoa
import QuartzCore

final class PillButton: NSView {
    private let bgView = NSView()
    private let actionBlock: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private let isAccent: Bool
    private let isDestructive: Bool

    var isSelected: Bool = false {
        didSet {
            if oldValue != isSelected {
                updateBackground()
            }
        }
    }

    init(frame: NSRect, title: String?, symbolName: String?, isAccent: Bool = false, isDestructive: Bool = false, cornerRadius: CGFloat = 8, action: @escaping () -> Void) {
        self.isAccent = isAccent
        self.isDestructive = isDestructive
        self.actionBlock = action
        super.init(frame: frame)

        self.wantsLayer = true

        bgView.frame = bounds
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = cornerRadius
        bgView.layer?.borderWidth = 1.0
        addSubview(bgView)

        let fgColor: NSColor
        if isAccent {
            fgColor = .white
        } else if isDestructive {
            fgColor = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.42, alpha: 1.0)
        } else {
            fgColor = NSColor.white.withAlphaComponent(0.92)
        }

        if let title = title, !title.isEmpty {
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            label.textColor = fgColor
            let textW = ceil(label.intrinsicContentSize.width)

            if let symName = symbolName, let sym = NSImage(systemSymbolName: symName, accessibilityDescription: nil) {
                let iconSize: CGFloat = 13
                let gap: CGFloat = 6
                let totalW = iconSize + gap + textW
                let startX = floor((frame.width - totalW) / 2)

                let iv = NSImageView(frame: NSRect(x: startX, y: floor((frame.height - iconSize) / 2), width: iconSize, height: iconSize))
                iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
                iv.contentTintColor = fgColor
                addSubview(iv)

                label.frame = NSRect(x: startX + iconSize + gap, y: floor((frame.height - 17) / 2), width: textW + 2, height: 17)
                addSubview(label)
            } else {
                label.alignment = .center
                label.frame = NSRect(x: 4, y: floor((frame.height - 17) / 2), width: frame.width - 8, height: 17)
                addSubview(label)
            }
        } else if let symName = symbolName, let sym = NSImage(systemSymbolName: symName, accessibilityDescription: nil) {
            let iconSize: CGFloat = 14
            let iv = NSImageView(frame: NSRect(x: floor((frame.width - iconSize) / 2), y: floor((frame.height - iconSize) / 2), width: iconSize, height: iconSize))
            iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            iv.contentTintColor = fgColor
            addSubview(iv)
        }

        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbolName: String, tintColor: NSColor? = nil) {
        guard let iv = subviews.compactMap({ $0 as? NSImageView }).first,
              let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }
        iv.image = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        if let tint = tintColor {
            iv.contentTintColor = tint
        }
    }

    private func updateBackground() {
        if isAccent || isSelected {
            let accent = Config.tokens.settingsAccent
            bgView.layer?.backgroundColor = accent.withAlphaComponent(isHovered ? 0.85 : 1.0).cgColor
            bgView.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        } else if isDestructive {
            bgView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(isHovered ? 0.28 : 0.16).cgColor
            bgView.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor
        } else {
            bgView.layer?.backgroundColor = NSColor.white.withAlphaComponent(isHovered ? 0.14 : 0.08).cgColor
            bgView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    private func animateScale(to scale: CGFloat, duration: CFTimeInterval, spring: Bool = false) {
        guard let layer = self.layer else { return }
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
        }
        let targetTransform = CATransform3DMakeScale(scale, scale, 1.0)
        if spring {
            let anim = CASpringAnimation(keyPath: "transform")
            anim.fromValue = layer.presentation()?.transform ?? layer.transform
            anim.toValue = targetTransform
            anim.damping = 14
            anim.stiffness = 280
            anim.mass = 0.8
            anim.duration = anim.settlingDuration
            layer.transform = targetTransform
            layer.add(anim, forKey: "pressSpring")
        } else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.transform = targetTransform
            CATransaction.commit()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        animateScale(to: 1.0, duration: 0.12)
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        animateScale(to: 0.93, duration: 0.08)
    }

    override func mouseUp(with event: NSEvent) {
        animateScale(to: 1.0, duration: 0.22, spring: true)
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            actionBlock()
        }
    }
}
