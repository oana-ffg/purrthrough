import AppKit

/// "Volume" row with a live slider for the status menu. 100% leaves the input
/// unchanged; up to 400% boosts a quiet line-level source.
@MainActor
final class VolumeMenuView: NSView {
    private let slider: NSSlider
    private let percent = NSTextField(labelWithString: "")
    private let onChange: (Float) -> Void

    init(volume: Float, maximum: Float, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: Double(volume), minValue: 0, maxValue: Double(maximum), target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 30))

        let title = NSTextField(labelWithString: "Volume")
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        percent.alignment = .right
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.setAccessibilityLabel("Purrthrough volume")

        for view in [title, slider, percent] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            percent.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            percent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percent.centerYAnchor.constraint(equalTo: centerYAnchor),
            percent.widthAnchor.constraint(equalToConstant: 44),
        ])
        showPercent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func sliderMoved() {
        onChange(slider.floatValue)
        showPercent()
    }

    private func showPercent() {
        percent.stringValue = "\(Int((slider.floatValue * 100).rounded()))%"
        slider.setAccessibilityValueDescription(percent.stringValue)
    }
}
