import Cocoa

// MARK: - Яркий нативный тумблер
final class AccentToggle: NSView {
    private var isOn: Bool
    private var accentColor: NSColor
    private let onChange: (Bool) -> Void
    private let knob = NSView()

    init(frame: NSRect, isOn: Bool, accentColor: NSColor, onChange: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.accentColor = accentColor
        self.onChange = onChange
        super.init(frame: frame)

        self.wantsLayer = true
        self.layer?.cornerRadius = frame.height / 2

        let knobSize = frame.height - 4
        knob.frame = NSRect(x: isOn ? frame.width - knobSize - 2 : 2, y: 2, width: knobSize, height: knobSize)
        knob.wantsLayer = true
        knob.layer?.cornerRadius = knobSize / 2
        knob.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(knob)

        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance(animated: Bool) {
        let knobSize = bounds.height - 4
        let targetX: CGFloat = isOn ? bounds.width - knobSize - 2 : 2
        let bgColor = isOn ? accentColor.cgColor : NSColor.white.withAlphaComponent(0.22).cgColor

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.layer?.backgroundColor = bgColor
                self.knob.animator().frame.origin.x = targetX
            }
        } else {
            self.layer?.backgroundColor = bgColor
            self.knob.frame.origin.x = targetX
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            isOn.toggle()
            updateAppearance(animated: true)
            onChange(isOn)
        }
    }
}

// MARK: - Переключатель сегментов без обрезки текста
final class AccentSegmentedControl: NSView {
    private let bgView = NSView()
    private let thumbView = NSView()
    private var labels: [NSTextField] = []
    private var selectedIndex: Int
    private var accentColor: NSColor
    private let onSelect: (Int) -> Void

    init(frame: NSRect, options: [String], selectedIndex: Int, accentColor: NSColor, onSelect: @escaping (Int) -> Void) {
        self.selectedIndex = selectedIndex
        self.accentColor = accentColor
        self.onSelect = onSelect
        super.init(frame: frame)

        bgView.frame = bounds
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 8
        bgView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        bgView.layer?.borderWidth = 1
        bgView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addSubview(bgView)

        let pad: CGFloat = 3
        let segW = floor((frame.width - pad * 2) / CGFloat(options.count))
        thumbView.frame = NSRect(x: pad + CGFloat(selectedIndex) * segW, y: pad, width: segW, height: frame.height - pad * 2)
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 6
        thumbView.layer?.backgroundColor = accentColor.cgColor
        addSubview(thumbView)

        for (idx, title) in options.enumerated() {
            let lbl = NSTextField(labelWithString: title)
            lbl.alignment = .center
            lbl.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            lbl.frame = NSRect(x: pad + CGFloat(idx) * segW, y: floor((frame.height - 16) / 2), width: segW, height: 16)
            addSubview(lbl)
            labels.append(lbl)
        }
        updateTextColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTextColors() {
        for (idx, lbl) in labels.enumerated() {
            lbl.textColor = (idx == selectedIndex) ? .white : NSColor.white.withAlphaComponent(0.65)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt), !labels.isEmpty else { return }
        let pad: CGFloat = 3
        let segW = floor((bounds.width - pad * 2) / CGFloat(labels.count))
        let idx = min(labels.count - 1, max(0, Int((pt.x - pad) / segW)))
        guard idx != selectedIndex else { return }
        selectedIndex = idx
        updateTextColors()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.thumbView.animator().frame.origin.x = pad + CGFloat(idx) * segW
        }
        onSelect(idx)
    }
}
