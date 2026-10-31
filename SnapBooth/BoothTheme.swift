import UIKit

/// Shared studio styling for the iPad and Mac Catalyst interfaces.
@MainActor
enum BoothTheme {
    static let canvas = color(0xF7F7F5)
    static let surface = color(0xFFFFFF)
    static let ink = color(0x202724)
    static let secondary = color(0x68716D)
    static let accent = color(0x184C47)
    static let accentSoft = color(0xE8EFEB)
    static let line = color(0xDFE4DF)
    static let stage = color(0x172320)

    enum ButtonRole {
        case primary
        case secondary
        case quiet
        case destructive
    }

    static func styleButton(
        _ button: UIButton,
        title: String,
        symbol: String? = nil,
        role: ButtonRole = .secondary
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 8
        configuration.titleAlignment = .center
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 12
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .callout)
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0

        if installMinimumHeight(on: button) {
            button.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (button: UIButton, _: UITraitCollection) in
                button.setNeedsUpdateConfiguration()
            }
        }
        button.configurationUpdateHandler = { button in
            updateButtonAppearance(button, role: role)
        }
        updateButtonAppearance(button, role: role)
    }

    static func styleSegments(_ selector: UISegmentedControl) {
        selector.backgroundColor = accentSoft
        selector.selectedSegmentTintColor = surface
        selector.tintColor = accent
        selector.layer.cornerRadius = 10
        selector.layer.cornerCurve = .continuous
        if installMinimumHeight(on: selector) {
            selector.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (selector: UISegmentedControl, _: UITraitCollection) in
                updateSegmentFonts(selector)
            }
        }
        updateSegmentFonts(selector)
    }

    static func makeLabel(
        _ text: String,
        textStyle: UIFont.TextStyle = .body,
        weight: UIFont.Weight = .regular,
        color: UIColor? = nil
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = color ?? ink
        label.font = font(for: textStyle, weight: weight, traits: label.traitCollection)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    static func makeSection(title: String, subtitle: String? = nil, views: [UIView]) -> UIView {
        let panel = UIView()
        panel.backgroundColor = surface
        panel.layer.cornerRadius = 18
        panel.layer.cornerCurve = .continuous
        panel.layer.borderWidth = 1
        panel.layer.borderColor = line.cgColor

        let heading = makeLabel(title, textStyle: .headline, weight: .semibold)
        heading.accessibilityTraits.insert(.header)
        let header = UIStackView(arrangedSubviews: [heading])
        header.axis = .vertical
        header.spacing = 5
        if let subtitle, !subtitle.isEmpty {
            header.addArrangedSubview(makeLabel(subtitle, textStyle: .subheadline, color: secondary))
        }

        let content = UIStackView(arrangedSubviews: views)
        content.axis = .vertical
        content.spacing = 12
        let stack = UIStackView(arrangedSubviews: views.isEmpty ? [header] : [header, content])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        // A section can be collapsed as an arranged subview of another stack.
        let bottom = stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20)
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            bottom
        ])
        return panel
    }

    private static func updateButtonAppearance(_ button: UIButton, role: ButtonRole) {
        guard var configuration = button.configuration else { return }
        let destructive = color(0xA13E35)
        let foreground: UIColor
        let background: UIColor
        switch role {
        case .primary:
            foreground = surface
            background = button.isHighlighted ? color(0x103A36) : accent
        case .secondary:
            foreground = ink
            background = button.isHighlighted ? accentSoft : surface
        case .quiet:
            foreground = accent
            background = button.isHighlighted ? accentSoft : .clear
        case .destructive:
            foreground = destructive
            background = button.isHighlighted ? color(0xF1DED9) : color(0xFAEFEC)
        }

        let resolvedForeground = button.isEnabled ? foreground : secondary.withAlphaComponent(0.65)
        let resolvedBackground = button.isEnabled ? background : canvas
        configuration.baseForegroundColor = resolvedForeground
        configuration.background.backgroundColor = resolvedBackground
        configuration.background.strokeColor = line
        configuration.background.strokeWidth = role == .secondary ? 1 : 0
        let titleFont = font(for: .callout, weight: .semibold, traits: button.traitCollection)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = titleFont
            outgoing.foregroundColor = resolvedForeground
            return outgoing
        }
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in resolvedForeground }
        button.configuration = configuration
    }

    private static func updateSegmentFonts(_ selector: UISegmentedControl) {
        let regular = font(for: .subheadline, weight: .medium, traits: selector.traitCollection)
        let selected = font(for: .subheadline, weight: .semibold, traits: selector.traitCollection)
        selector.setTitleTextAttributes([.font: regular, .foregroundColor: secondary], for: .normal)
        selector.setTitleTextAttributes([.font: selected, .foregroundColor: accent], for: .selected)
        selector.setTitleTextAttributes([.font: regular, .foregroundColor: secondary.withAlphaComponent(0.55)], for: .disabled)
        selector.setTitleTextAttributes([.font: selected, .foregroundColor: accent], for: .highlighted)
    }

    /// A named constraint also prevents duplicate trait registrations when restyling.
    @discardableResult
    private static func installMinimumHeight(on view: UIView) -> Bool {
        let identifier = "BoothTheme.minimumHeight"
        guard !view.constraints.contains(where: { $0.identifier == identifier }) else { return false }
        let minimum = view.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        // UIStackView temporarily imposes zero height on hidden controls.
        minimum.priority = UILayoutPriority(999)
        minimum.identifier = identifier
        minimum.isActive = true
        return true
    }

    private static func font(for style: UIFont.TextStyle, weight: UIFont.Weight, traits: UITraitCollection) -> UIFont {
        let standard = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let base = UIFont.systemFont(ofSize: standard.pointSize, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traits)
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
