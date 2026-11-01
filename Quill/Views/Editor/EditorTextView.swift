import SwiftUI
import UIKit

/// The writing surface. UIKit because TextEditor can't scroll a title with the text, align
/// exactly with it, or style Markdown as it's typed. The header scrolls as part of the page.
struct EditorTextView<Header: View>: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    @Binding var isFocused: Bool
    /// Bump to move the keyboard to the text.
    let focusRequest: Int
    let isEditable: Bool
    let margin: CGFloat
    @ViewBuilder let header: () -> Header

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(text: $text, selection: $selection, isFocused: $isFocused) }

    func makeUIView(context: Context) -> PageTextView {
        let view = PageTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "editor"
        view.typingAttributes = MarkdownStyler.base
        view.placeholder.text = "Write…"
        return view
    }

    func updateUIView(_ view: PageTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.selection = $selection
        coordinator.isFocused = $isFocused
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        view.margin = margin
        view.isEditable = isEditable
        view.tintColor = UIColor(.cursor)
        view.setHeader(UIHostingConfiguration { header() }.margins(.all, 0))
        // While the keyboard is composing the view holds text SwiftUI hasn't seen, so writing back
        // would double what's been typed.
        guard view.markedTextRange == nil else { return }
        if view.text != text {
            if view.isEditable, view.hasText { view.replaceChanges(with: text) } else { view.text = text }
            view.applyMarkdownStyle()
            view.placeholder.isHidden = !text.isEmpty
        }
        // Only a new request from SwiftUI moves the cursor. An older value still on its way back
        // would otherwise undo a tap, like the first tap after Edit.
        if case .selection(let range)? = selection?.indices, range.upperBound <= text.endIndex {
            let wanted = NSRange(range, in: text)
            if wanted != coordinator.lastSelection {
                coordinator.lastSelection = wanted
                if view.selectedRange != wanted { view.selectedRange = wanted }
            }
        }
        if focusRequest != coordinator.handledFocusRequest {
            coordinator.handledFocusRequest = focusRequest
            view.focusWhenReady()
        }
    }

}

/// Not nested in the generic view: Swift 6.3's optimizer crashes on this class's deinit there.
final class EditorCoordinator: NSObject, UITextViewDelegate {
    var text: Binding<String>
    var selection: Binding<TextSelection?>
    var isFocused: Binding<Bool>
    var isUpdating = false
    var handledFocusRequest = 0
    var lastSelection: NSRange?

    init(text: Binding<String>, selection: Binding<TextSelection?>, isFocused: Binding<Bool>) {
        self.text = text
        self.selection = selection
        self.isFocused = isFocused
    }

    func textViewDidChange(_ view: UITextView) {
        guard !isUpdating else { return }
        text.wrappedValue = view.text
        (view as? PageTextView)?.placeholder.isHidden = !view.text.isEmpty
        if view.markedTextRange == nil { view.applyMarkdownStyle() }
    }

    func textViewDidChangeSelection(_ view: UITextView) {
        guard !isUpdating, let range = Range(view.selectedRange, in: view.text) else { return }
        lastSelection = view.selectedRange
        selection.wrappedValue = TextSelection(range: range)
    }

    func textViewDidBeginEditing(_ view: UITextView) { setFocused(true) }
    func textViewDidEndEditing(_ view: UITextView) { setFocused(false) }

    /// `updateUIView` can move the keyboard, and SwiftUI state can't change during an update.
    private func setFocused(_ focused: Bool) {
        guard isUpdating else {
            isFocused.wrappedValue = focused
            return
        }
        DispatchQueue.main.async { self.isFocused.wrappedValue = focused }
    }
}

private extension UITextView {
    func applyMarkdownStyle() {
        MarkdownStyler.style(textStorage)
        typingAttributes = MarkdownStyler.base
    }
}

final class PageTextView: UITextView {
    /// About 72 characters, the longest line that's still comfortable to write in.
    static let maxWidth = ceil(("0" as NSString).size(withAttributes: [.font: MarkdownStyler.bodyFont]).width * 72)

    var margin: CGFloat = 20 { didSet { if margin != oldValue { setNeedsLayout() } } }
    let placeholder = UILabel()
    private var headerView: (any UIView & UIContentView)?
    private var wantsFocus = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        textContainer.lineFragmentPadding = 0
        placeholder.font = MarkdownStyler.bodyFont
        placeholder.textColor = .tertiaryLabel
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setHeader(_ configuration: some UIContentConfiguration) {
        if let headerView {
            headerView.configuration = configuration
        } else {
            let view = configuration.makeContentView()
            addSubview(view)
            headerView = view
        }
        setNeedsLayout()
    }

    /// Changes only what differs, through UITextInput, so Undo can take it back. Setting `text`
    /// would clear the undo stack.
    func replaceChanges(with new: String) {
        let old: String = text
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
        let kept = min(suffix, min(old.count, new.count) - prefix)
        let start = old.index(old.startIndex, offsetBy: prefix)
        let changed = NSRange(start..<old.index(old.endIndex, offsetBy: -kept), in: old)
        let replacement = String(new[new.index(new.startIndex, offsetBy: prefix)..<new.index(new.endIndex, offsetBy: -kept)])
        guard let from = position(from: beginningOfDocument, offset: changed.location),
              let to = position(from: from, offset: changed.length),
              let range = textRange(from: from, to: to) else {
            text = new
            return
        }
        replace(range, withText: replacement)
    }

    func focusWhenReady() {
        if window != nil { becomeFirstResponder() } else { wantsFocus = true }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, wantsFocus {
            wantsFocus = false
            DispatchQueue.main.async { self.becomeFirstResponder() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = max(margin, (bounds.width - Self.maxWidth) / 2)
        let width = bounds.width - side * 2
        guard width > 0 else { return }
        var top: CGFloat = 20
        if let headerView {
            let height = headerView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            headerView.frame = CGRect(x: side, y: 20, width: width, height: height)
            top += height
        }
        let insets = UIEdgeInsets(top: top, left: side, bottom: 40, right: side)
        if textContainerInset != insets { textContainerInset = insets }
        placeholder.frame = CGRect(x: side, y: top, width: width, height: placeholder.font.lineHeight)
    }
}
