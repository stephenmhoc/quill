import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the format bar and the edit menu can do to the page.
struct PageFormatting {
    let format: (MarkdownFormat) -> Void
    let insertImage: () -> Void
    let canInsertImage: Bool
}

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
    /// What the page belongs to, so the same text view comes back for it after a layout change.
    let reuseID: UUID
    let reuse: EditorReuse
    /// Nil hides the format bar, as focus mode does.
    let formatting: PageFormatting?
    /// Pictures pasted or dropped on the page. Text goes in as usual.
    let onImages: ([NSItemProvider]) -> Void
    /// Esc, which leaves focus mode.
    let onEscape: (() -> Void)?
    @ViewBuilder let header: () -> Header

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(text: $text, selection: $selection, isFocused: $isFocused) }

    func makeUIView(context: Context) -> PageTextView {
        if let view = reuse.view(for: reuseID) {
            view.delegate = context.coordinator
            // The caret is where it was, and formatting needs to know.
            DispatchQueue.main.async { context.coordinator.textViewDidChangeSelection(view) }
            return view
        }
        let view = PageTextView()
        reuse.keep(view, for: reuseID)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.isFindInteractionEnabled = true
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
        view.onImages = onImages
        view.onEscape = onEscape
        view.setFormatting(isEditable ? formatting : nil)
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
    /// Where typing has changed the text since it was last styled.
    private var edited: NSRange?
    private var isContinuingList = false

    init(text: Binding<String>, selection: Binding<TextSelection?>, isFocused: Binding<Bool>) {
        self.text = text
        self.selection = selection
        self.isFocused = isFocused
    }

    func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
        guard !isContinuingList else { return true }
        let changed = NSRange(location: range.location, length: (replacement as NSString).length)
        edited = edited.map { NSUnionRange($0, changed) } ?? changed
        guard replacement == "\n", range.length == 0, view.markedTextRange == nil,
              let (lineRange, replacementText) = ListContinuation.edit(for: view.text as NSString, at: range.location) else {
            return true
        }
        // Through UITextInput, so Undo takes it back in one step.
        isContinuingList = true
        defer { isContinuingList = false }
        guard let start = view.position(from: view.beginningOfDocument, offset: lineRange.location),
              let end = view.position(from: start, offset: lineRange.length),
              let textRange = view.textRange(from: start, to: end) else { return true }
        edited = NSUnionRange(edited ?? lineRange, NSRange(location: lineRange.location, length: (replacementText as NSString).length))
        view.replace(textRange, withText: replacementText)
        if view.text != text.wrappedValue { textViewDidChange(view) }
        return false
    }

    func textViewDidChange(_ view: UITextView) {
        guard !isUpdating else { return }
        text.wrappedValue = view.text
        (view as? PageTextView)?.placeholder.isHidden = !view.text.isEmpty
        if view.markedTextRange == nil {
            view.applyMarkdownStyle(around: edited)
            edited = nil
        }
    }

    func textViewDidChangeSelection(_ view: UITextView) {
        guard !isUpdating, let range = Range(view.selectedRange, in: view.text) else { return }
        lastSelection = view.selectedRange
        selection.wrappedValue = TextSelection(range: range)
    }

    func textViewDidBeginEditing(_ view: UITextView) { setFocused(true) }
    func textViewDidEndEditing(_ view: UITextView) { setFocused(false) }

    /// Bold, Italic and Link beside Copy and Paste, for a selection.
    func textView(_ view: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0, view.isEditable, let formatting = (view as? PageTextView)?.formatting else { return nil }
        let format = UIMenu(title: "Format", image: UIImage(systemName: "bold.italic.underline"), children: [
            UIAction(title: "Bold", image: UIImage(systemName: "bold")) { _ in formatting.format(.bold) },
            UIAction(title: "Italic", image: UIImage(systemName: "italic")) { _ in formatting.format(.italic) },
            UIAction(title: "Link", image: UIImage(systemName: "link")) { _ in formatting.format(.link) },
        ])
        return UIMenu(children: suggestedActions + [format])
    }

    /// `updateUIView` can move the keyboard, and SwiftUI state can't change during an update.
    private func setFocused(_ focused: Bool) {
        guard isUpdating else {
            isFocused.wrappedValue = focused
            return
        }
        DispatchQueue.main.async { self.isFocused.wrappedValue = focused }
    }
}

/// Return in a list starts the next item, and Return on an empty item ends the list.
enum ListContinuation {
    private static let item = try! NSRegularExpression(pattern: "^([ \\t]*)(?:([-*+])( \\[[ xX]\\])?|(\\d+)([.)])) ")
    /// Three or more of one of `-`, `*` or `_`, spaced or not, and nothing else.
    private static let rule = try! NSRegularExpression(pattern: "^[ \\t]*([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")

    /// The line to replace and what to put there, or nil for an ordinary Return.
    static func edit(for text: NSString, at caret: Int) -> (NSRange, String)? {
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let lineStart = line.location
        var lineEnd = NSMaxRange(line)
        if lineEnd > lineStart, text.character(at: lineEnd - 1) == 0x0A { lineEnd -= 1 }
        let content = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
        let whole = NSRange(location: 0, length: (content as NSString).length)
        // `* * *` and `- - -` are rules, not lists.
        guard rule.firstMatch(in: content, range: whole) == nil else { return nil }
        guard let match = item.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) else {
            return nil
        }
        let markerEnd = lineStart + match.range.length
        // In the marker itself, Return just breaks the line.
        guard caret >= markerEnd else { return nil }
        let marker = (content as NSString).substring(with: match.range)
        if lineEnd == markerEnd {
            // An empty item stops the list, with a blank line in place of its marker. Without one
            // the next paragraph would join the last item.
            return (NSRange(location: lineStart, length: match.range.length), "\n")
        }
        let content_ = content as NSString
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : content_.substring(with: range)
        }
        let indent = group(1) ?? ""
        let next: String
        if let number = group(4).flatMap(Int.init), let delimiter = group(5) {
            next = "\(indent)\(number + 1)\(delimiter) "
        } else if let bullet = group(2) {
            // A ticked task starts an unticked one.
            next = "\(indent)\(bullet)\(group(3) == nil ? "" : " [ ]") "
        } else {
            next = marker
        }
        return (NSRange(location: caret, length: 0), "\n" + next)
    }
}

private extension UITextView {
    func applyMarkdownStyle(around range: NSRange? = nil) {
        MarkdownStyler.style(textStorage, around: range)
        typingAttributes = MarkdownStyler.base
    }
}

/// Holds one scene's text view between a split view and a stack. Only the open page's is kept.
final class EditorReuse {
    private var id: UUID?
    private weak var view: PageTextView?

    func view(for id: UUID) -> PageTextView? { self.id == id ? view : nil }

    func keep(_ view: PageTextView, for id: UUID) {
        self.id = id
        self.view = view
    }
}

final class PageTextView: UITextView {
    var margin: CGFloat = 20 { didSet { if margin != oldValue { setNeedsLayout() } } }
    let placeholder = UILabel()
    private var headerView: (any UIView & UIContentView)?
    private var wantsFocus = false
    /// Set when the view leaves a window with the keyboard. Back in one straight away, as when
    /// the layout changes, it takes the keyboard again.
    private var leftWithKeyboardAt: Date?
    var onImages: (([NSItemProvider]) -> Void)?
    var onEscape: (() -> Void)?
    private(set) var formatting: PageFormatting?
    private lazy var imageDrop = ImageDrop(page: self)
    private lazy var formatBar = makeFormatBar()

    /// About 72 characters, the longest line that's still comfortable to write in.
    private var maxWidth: CGFloat {
        ceil(("0" as NSString).size(withAttributes: [.font: MarkdownStyler.bodyFont]).width * 72)
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        textContainer.lineFragmentPadding = 0
        placeholder.font = MarkdownStyler.bodyFont
        placeholder.textColor = .tertiaryLabel
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
        addInteraction(UIDropInteraction(delegate: imageDrop))
        // The styles are set by hand, so a new text size has to restyle the page.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: PageTextView, _) in
            view.placeholder.font = MarkdownStyler.bodyFont
            view.applyMarkdownStyle()
            view.setNeedsLayout()
        }
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

    // MARK: Format bar

    /// Above the keyboard on iPhone. On iPad it joins the shortcuts bar, which also shows with a
    /// hardware keyboard, beside Undo and Paste.
    func setFormatting(_ formatting: PageFormatting?) {
        let wasShown = self.formatting != nil
        self.formatting = formatting
        imageItem.isEnabled = formatting?.canInsertImage ?? false
        formatBar.isImageEnabled = imageItem.isEnabled
        guard wasShown != (formatting != nil) else { return }
        if traitCollection.userInterfaceIdiom == .pad {
            inputAssistantItem.trailingBarButtonGroups = formatting == nil ? [] : [
                UIBarButtonItemGroup(barButtonItems: formatItems, representativeItem: nil),
            ]
        } else {
            inputAccessoryView = formatting == nil ? nil : formatBar
        }
        if isFirstResponder { reloadInputViews() }
    }

    private static let formatActions: [FormatBar.Action] = [
        .init(title: "Bold", symbol: "bold") { $0.format(.bold) },
        .init(title: "Italic", symbol: "italic") { $0.format(.italic) },
        .init(title: "Heading", symbol: "number") { $0.format(.heading) },
        .init(title: "List", symbol: "list.bullet") { $0.format(.bullet) },
        .init(title: "Quote", symbol: "text.quote") { $0.format(.quote) },
        .init(title: "Link", symbol: "link") { $0.format(.link) },
        .init(title: "Insert Image", symbol: "photo", isImage: true) { $0.insertImage() },
    ]

    private lazy var formatItems: [UIBarButtonItem] = Self.formatActions.map { action in
        let item = UIBarButtonItem(title: action.title, image: UIImage(systemName: action.symbol), primaryAction: UIAction { [weak self] _ in
            if let formatting = self?.formatting { action.perform(formatting) }
        })
        item.accessibilityLabel = action.title
        return item
    }

    private var imageItem: UIBarButtonItem { formatItems[Self.formatActions.firstIndex { $0.isImage }!] }

    private func makeFormatBar() -> FormatBar {
        FormatBar(actions: Self.formatActions,
                  perform: { [weak self] action in if let formatting = self?.formatting { action.perform(formatting) } },
                  hide: { [weak self] in _ = self?.resignFirstResponder() })
    }

    override var keyCommands: [UIKeyCommand]? {
        guard onEscape != nil else { return super.keyCommands }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape]
    }

    @objc private func escapePressed() { onEscape?() }

    // MARK: Pictures

    /// A picture on its own. Anything with text, like a link with its preview, pastes as text.
    private var pasteboardHasOnlyImages: Bool {
        let board = UIPasteboard.general
        return board.hasImages && !board.hasStrings && !board.hasURLs
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, onImages != nil, pasteboardHasOnlyImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if isEditable, let onImages, pasteboardHasOnlyImages {
            onImages(UIPasteboard.general.itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
        } else {
            super.paste(sender)
        }
    }

    /// Photos and Files drag pictures with no text, which a plain text view would refuse.
    fileprivate final class ImageDrop: NSObject, UIDropInteractionDelegate {
        weak var page: PageTextView?

        init(page: PageTextView) { self.page = page }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            guard let page, page.isEditable, page.onImages != nil else { return false }
            return session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
                && !session.hasItemsConforming(toTypeIdentifiers: [UTType.text.identifier, UTType.url.identifier])
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let page else { return }
            // In where it was dropped, not wherever the caret happened to be.
            if let position = page.closestPosition(to: session.location(in: page)) {
                page.selectedTextRange = page.textRange(from: position, to: position)
            }
            page.onImages?(session.items.map(\.itemProvider).filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
        }
    }

    // MARK: Editing

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

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil, isFirstResponder { leftWithKeyboardAt = .now }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let returning = leftWithKeyboardAt.map { Date.now.timeIntervalSince($0) < 1 } ?? false
        leftWithKeyboardAt = nil
        if wantsFocus || returning {
            wantsFocus = false
            DispatchQueue.main.async { self.becomeFirstResponder() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = max(margin, (bounds.width - maxWidth) / 2)
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
