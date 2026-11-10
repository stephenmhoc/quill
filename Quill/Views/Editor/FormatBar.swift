import UIKit

/// Formatting above the iPhone keyboard. Hide Keyboard stays at the trailing edge, and the
/// formatting scrolls beside it when there isn't room for all of it. A toolbar would push the
/// last items into a More menu or past the edge instead, taking Hide Keyboard with them.
final class FormatBar: UIView {
    struct Action {
        let title: String
        let symbol: String
        var isImage = false
        let perform: (PageFormatting) -> Void
    }

    var isImageEnabled = false { didSet { imageButton?.isEnabled = isImageEnabled } }

    private static let target: CGFloat = 44
    private static let inset: CGFloat = 4
    private static let margin: CGFloat = 12
    private weak var imageButton: UIButton?

    init(actions: [Action], perform: @escaping (Action) -> Void, hide: @escaping () -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.target + Self.inset * 2))
        autoresizingMask = .flexibleWidth

        let buttons = actions.map { action in
            let button = Self.button(action.title, action.symbol, glass: false) { perform(action) }
            if action.isImage {
                button.isEnabled = isImageEnabled
                imageButton = button
            }
            return button
        }
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.layer.cornerRadius = Self.target / 2
        scroll.layer.cornerCurve = .continuous
        scroll.addSubview(stack)

        let formats: UIView
        if #available(iOS 26, *) {
            backgroundColor = .clear
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .capsule()
            glass.contentView.addSubview(scroll)
            formats = glass
        } else {
            let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            material.translatesAutoresizingMaskIntoConstraints = false
            addSubview(material)
            NSLayoutConstraint.activate([
                material.leadingAnchor.constraint(equalTo: leadingAnchor),
                material.trailingAnchor.constraint(equalTo: trailingAnchor),
                material.topAnchor.constraint(equalTo: topAnchor),
                material.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            formats = UIView()
            formats.addSubview(scroll)
        }
        formats.translatesAutoresizingMaskIntoConstraints = false
        addSubview(formats)

        let hideButton = Self.button("Hide Keyboard", "keyboard.chevron.compact.down", glass: true, action: hide)
        addSubview(hideButton)

        let area = safeAreaLayoutGuide
        // Hugs the formatting when it fits, and gives way to Hide Keyboard when it doesn't.
        let hug = scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        hug.priority = .defaultHigh
        NSLayoutConstraint.activate([
            hideButton.trailingAnchor.constraint(equalTo: area.trailingAnchor, constant: -Self.margin),
            hideButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            formats.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: Self.margin),
            formats.trailingAnchor.constraint(lessThanOrEqualTo: hideButton.leadingAnchor, constant: -8),
            formats.centerYAnchor.constraint(equalTo: centerYAnchor),
            formats.heightAnchor.constraint(equalToConstant: Self.target),

            scroll.leadingAnchor.constraint(equalTo: formats.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: formats.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: formats.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: formats.bottomAnchor),
            hug,

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        // The stack's insets are inside the scroll view, so its width needs them too.
        hug.constant = Self.inset * 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.target + Self.inset * 2)
    }

    private static func button(_ title: String, _ symbol: String, glass: Bool, action: @escaping () -> Void) -> UIButton {
        var configuration: UIButton.Configuration
        if glass, #available(iOS 26, *) {
            configuration = .glass()
        } else {
            configuration = .plain()
        }
        configuration.image = UIImage(systemName: symbol)
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = title
        button.largeContentTitle = title
        button.showsLargeContentViewer = true
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: target),
            button.heightAnchor.constraint(equalToConstant: target),
        ])
        return button
    }
}
