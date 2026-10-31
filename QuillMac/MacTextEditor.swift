import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The writing surface. AppKit for the same reasons as iOS, and it brings the Mac's own spelling,
/// Find and undo with it. The header scrolls as part of the page.
struct MacTextEditor<Header: View>: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    /// Bump to move the cursor to the text.
    let focusRequest: Int
    let isEditable: Bool
    let onImages: ([Data]) -> Void
    @ViewBuilder let header: () -> Header

    func makeCoordinator() -> MacEditorCoordinator { MacEditorCoordinator(text: $text, selection: $selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = MacPageTextView()
        view.delegate = context.coordinator
        view.string = text
        MarkdownStyler.style(view.textStorage!)

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MacPageTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.selection = $selection
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        view.onImages = onImages
        view.isEditable = isEditable
        view.setHeader(AnyView(header()))
        if view.string != text {
            view.replaceChanges(with: text)
            MarkdownStyler.style(view.textStorage!)
            view.needsDisplay = true
        }
        // Only a new request from SwiftUI moves the cursor. An older value still on its way back
        // would otherwise undo a click.
        if case .selection(let range)? = selection?.indices, range.upperBound <= text.endIndex {
            let wanted = NSRange(range, in: text)
            if wanted != coordinator.lastSelection {
                coordinator.lastSelection = wanted
                if view.selectedRange() != wanted { view.setSelectedRange(wanted) }
            }
        }
        if focusRequest != coordinator.handledFocusRequest {
            coordinator.handledFocusRequest = focusRequest
            view.focusWhenReady()
        }
    }
}

/// Not nested in the generic view: Swift 6.3's optimizer crashes on this class's deinit there.
final class MacEditorCoordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var selection: Binding<TextSelection?>
    var isUpdating = false
    var handledFocusRequest = 0
    var lastSelection: NSRange?

    init(text: Binding<String>, selection: Binding<TextSelection?>) {
        self.text = text
        self.selection = selection
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdating, let view = notification.object as? NSTextView else { return }
        text.wrappedValue = view.string
        if !view.hasMarkedText() {
            MarkdownStyler.style(view.textStorage!)
            view.typingAttributes = MarkdownStyler.base
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isUpdating, let view = notification.object as? NSTextView,
              let range = Range(view.selectedRange(), in: view.string) else { return }
        lastSelection = view.selectedRange()
        selection.wrappedValue = TextSelection(range: range)
    }
}

final class MacPageTextView: NSTextView {
    /// About 72 characters, the longest line that's still comfortable to write in.
    static let maxWidth = ceil(("0" as NSString).size(withAttributes: [.font: MarkdownStyler.bodyFont]).width * 72)
    private static let margin: CGFloat = 40
    private static let topInset: CGFloat = 28
    private static let bottomInset: CGFloat = 60

    var onImages: (([Data]) -> Void)?
    private var headerController: NSHostingController<AnyView>?
    private var top = MacPageTextView.topInset
    private var wantsFocus = false

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        autoresizingMask = .width
        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        drawsBackground = false
        insertionPointColor = NSColor(.cursor)
        typingAttributes = MarkdownStyler.base
        allowsUndo = true
        isRichText = false
        importsGraphics = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = true
        // Markdown is plain text: a curly quote or an em dash would change what gets published.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        setAccessibilityIdentifier("editor")
        registerForDraggedTypes([.fileURL])
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: The page

    func setHeader(_ header: AnyView) {
        if let headerController {
            headerController.rootView = header
        } else {
            let controller = NSHostingController(rootView: header)
            controller.sizingOptions = []
            addSubview(controller.view)
            headerController = controller
        }
        layOutPage()
    }

    override func setFrameSize(_ size: NSSize) {
        let widthChanged = size.width != frame.width
        super.setFrameSize(size)
        if widthChanged { layOutPage() }
    }

    /// The inset is the same above and below, so the origin moves the text down below the header.
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: top) }

    private func layOutPage() {
        let side = max(Self.margin, (bounds.width - Self.maxWidth) / 2)
        let width = bounds.width - side * 2
        guard width > 0 else { return }
        var height: CGFloat = 0
        if let headerController {
            height = headerController.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude)).height
            headerController.view.frame = NSRect(x: side, y: Self.topInset, width: width, height: height)
        }
        top = Self.topInset + height
        textContainerInset = NSSize(width: side, height: (top + Self.bottomInset) / 2)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, isEditable else { return }
        ("Write…" as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: MarkdownStyler.bodyFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    // MARK: Text from SwiftUI

    /// Changes only what differs, through the undo-aware path, so Undo can take it back.
    func replaceChanges(with new: String) {
        let old = string
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
        let kept = min(suffix, min(old.count, new.count) - prefix)
        let start = old.index(old.startIndex, offsetBy: prefix)
        let changed = NSRange(start..<old.index(old.endIndex, offsetBy: -kept), in: old)
        let replacement = String(new[new.index(new.startIndex, offsetBy: prefix)..<new.index(new.endIndex, offsetBy: -kept)])
        guard isEditable, shouldChangeText(in: changed, replacementString: replacement) else {
            string = new
            return
        }
        textStorage?.replaceCharacters(in: changed, with: replacement)
        didChangeText()
    }

    func focusWhenReady() {
        if let window { window.makeFirstResponder(self) } else { wantsFocus = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, wantsFocus {
            wantsFocus = false
            DispatchQueue.main.async { window.makeFirstResponder(self) }
        }
    }

    // MARK: Images

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        // Text wins: copying from a web page often carries a picture of itself too.
        if board.string(forType: .string) == nil, let images = Self.images(on: board) {
            onImages?(images)
        } else {
            super.paste(sender)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.imageFiles(on: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.imageFiles(on: sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = Self.imageFiles(on: sender.draggingPasteboard)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        onImages?(files.compactMap { try? Data(contentsOf: $0) })
        return true
    }

    private static func imageFiles(on board: NSPasteboard) -> [URL] {
        board.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
    }

    private static func images(on board: NSPasteboard) -> [Data]? {
        let files = imageFiles(on: board)
        if !files.isEmpty { return files.compactMap { try? Data(contentsOf: $0) } }
        return (board.data(forType: .png) ?? board.data(forType: .tiff)).map { [$0] }
    }
}
