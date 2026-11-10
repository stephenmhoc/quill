import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A change the editor makes to its own text, so it's one step in Undo with a name.
struct EditorCommand: Equatable {
    enum Action {
        case format(MarkdownFormat)
        case insert(String, name: String)
    }

    let id: Int
    let action: Action

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// The writing surface. AppKit for the same reasons as iOS, and it brings the Mac's own spelling,
/// substitutions, Find and undo with it. The header scrolls as part of the page.
struct MacTextEditor<Header: View>: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    /// Bump to move the cursor to the text.
    let focusRequest: Int
    let isEditable: Bool
    /// Behind the lock screen: the page keeps its place, but takes no typing.
    var isLocked = false
    var textSize = MarkdownStyler.textSize
    var command: EditorCommand?
    let onImages: ([Data]) -> Void
    let onFocus: (Bool) -> Void
    /// ↑ on the first line, or ⇧Tab: on to the title. Nil when there's no title to go to.
    var onLeaveTop: (() -> Void)?
    /// Esc, once the find bar and any composing are dealt with. True if it was used.
    var onEscape: () -> Bool = { false }
    var onSave: () -> Void = {}
    /// Where Focus Mode finds this page to borrow it.
    var stage: FocusStage?
    @ViewBuilder let header: () -> Header

    func makeCoordinator() -> MacEditorCoordinator { MacEditorCoordinator(text: $text, selection: $selection) }

    func makeNSView(context: Context) -> MacPageHost {
        let view = MacPageTextView()
        view.delegate = context.coordinator
        view.string = text
        MarkdownStyler.style(view.textStorage!)
        context.coordinator.textSize = textSize
        context.coordinator.handledCommand = command?.id

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let host = MacPageHost(scroll: scroll)
        context.coordinator.stage = stage
        // After this update: the stage is watched, and changing it during one is a SwiftUI error.
        DispatchQueue.main.async { [weak host, stage] in stage?.page = host }
        return host
    }

    static func dismantleNSView(_ host: MacPageHost, coordinator: MacEditorCoordinator) {
        // It may be on loan to Focus Mode, outside this view.
        host.scroll.removeFromSuperview()
        guard let stage = coordinator.stage else { return }
        DispatchQueue.main.async { if stage.page === host { stage.page = nil } }
    }

    func updateNSView(_ host: MacPageHost, context: Context) {
        let scroll = host.scroll
        guard let view = scroll.documentView as? MacPageTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.selection = $selection
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        view.onImages = onImages
        view.onFocus = onFocus
        view.onLeaveTop = onLeaveTop
        view.onEscape = onEscape
        view.onSave = onSave
        view.onFormat = { [weak view, weak coordinator] format in
            guard let view, let coordinator else { return }
            coordinator.nextCommand -= 1
            view.run(EditorCommand(id: coordinator.nextCommand, action: .format(format)))
        }
        view.isEditable = isEditable && !isLocked
        view.isLocked = isLocked
        view.setHeader(AnyView(header()))
        if textSize != coordinator.textSize {
            coordinator.textSize = textSize
            view.textSizeChanged()
        }
        // While macOS is composing (a prediction, a dead key, an input method) the view holds text
        // SwiftUI hasn't seen. Writing back then doubles what's been typed, and can crash.
        guard !view.hasMarkedText() else { return }
        if view.string != text {
            // Only a change from elsewhere gets here (a revert, or undoing one). The typing steps
            // belong to the text it replaced, so they go, and this change isn't one either.
            view.string = text
            coordinator.undo.removeAllActions()
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
        if let command, command.id != coordinator.handledCommand {
            coordinator.handledCommand = command.id
            // After this update, so the text it writes back reaches SwiftUI as a normal edit.
            DispatchQueue.main.async { view.run(command) }
        }
    }
}

/// Not nested in the generic view: Swift 6.3's optimizer crashes on this class's deinit there.
final class MacEditorCoordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var selection: Binding<TextSelection?>
    var isUpdating = false
    var handledFocusRequest = 0
    var handledCommand: Int?
    /// Commands from the context menu count down, so they never meet SwiftUI's.
    var nextCommand = 0
    var lastSelection: NSRange?
    var textSize = MarkdownStyler.textSize
    /// The page's typing steps, which go with the page. The window's own steps (a deleted entry,
    /// a revert) stay on the window's manager, which Undo reaches once these run out.
    let undo = UndoManager()
    weak var stage: FocusStage?
    /// What changed since the last restyle, so only those paragraphs need it.
    private var edited: NSRange?
    private var edits = 0

    init(text: Binding<String>, selection: Binding<TextSelection?>) {
        self.text = text
        self.selection = selection
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
        edits += 1
        edited = NSRange(location: range.location, length: (string as NSString?)?.length ?? 0)
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdating, let view = notification.object as? NSTextView else { return }
        // Marked text isn't written yet. A prediction only counts once Tab accepts it.
        var written = view.string
        if view.hasMarkedText(), let marked = Range(view.markedRange(), in: written) { written.removeSubrange(marked) }
        text.wrappedValue = written
        if view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true {
            // AppKit puts the old attributes back after this, so style once it's finished.
            resetEdits()
            DispatchQueue.main.async { self.style(view, around: nil) }
        } else if !view.hasMarkedText() {
            // One known edit restyles its own paragraphs; anything else, the lot.
            style(view, around: edits == 1 ? edited : nil)
            resetEdits()
        }
    }

    private func resetEdits() {
        edits = 0
        edited = nil
    }

    private func style(_ view: NSTextView, around range: NSRange?) {
        MarkdownStyler.style(view.textStorage!, around: range)
        view.typingAttributes = MarkdownStyler.base
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isUpdating, let view = notification.object as? NSTextView,
              let range = Range(view.selectedRange(), in: view.string) else { return }
        lastSelection = view.selectedRange()
        selection.wrappedValue = TextSelection(range: range)
    }
}

/// The editor's view: it holds the scroll view, which Focus Mode borrows and gives back, so
/// SwiftUI's view stays where SwiftUI put it.
final class MacPageHost: NSView {
    let scroll: NSScrollView
    var textView: MacPageTextView? { scroll.documentView as? MacPageTextView }

    init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        reclaim()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Into Focus Mode's surface, filling it.
    func lend(to surface: NSView) {
        scroll.removeFromSuperview()
        scroll.frame = surface.bounds
        scroll.autoresizingMask = [.width, .height]
        surface.addSubview(scroll)
    }

    /// Back here, where the column has it.
    func reclaim() {
        guard scroll.superview !== self else { return }
        scroll.removeFromSuperview()
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }
}

final class MacPageTextView: NSTextView {
    /// About 72 characters, the longest line that's still comfortable to write in.
    static var maxWidth: CGFloat { ceil(("0" as NSString).size(withAttributes: [.font: MarkdownStyler.bodyFont]).width * 72) }
    private static let margin: CGFloat = 40
    private static let topInset: CGFloat = 28
    private static let bottomInset: CGFloat = 60

    var onImages: (([Data]) -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onLeaveTop: (() -> Void)?
    var onEscape: () -> Bool = { false }
    var onSave: () -> Void = {}
    var onFormat: ((MarkdownFormat) -> Void)?
    var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            if isLocked, window?.firstResponder === self {
                wantsFocus = true
                window?.makeFirstResponder(nil)
            } else if !isLocked, wantsFocus {
                wantsFocus = false
                DispatchQueue.main.async { [weak self] in self?.focusWhenReady() }
            }
        }
    }
    private var headerController: NSHostingController<AnyView>?
    private var headerHeight: CGFloat = 0
    private var laidOutWidth: CGFloat = -1
    private var top = MacPageTextView.topInset
    private var wantsFocus = false
    /// Off while the saved choices are put back, so putting them back doesn't save them again.
    private var remembersSettings = false

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
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
        // Markdown sets the type; the font panel can only add attributes nothing keeps.
        usesFontPanel = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = true
        // Quotes, dashes and replacements follow the Mac's own settings, and Edit > Substitutions,
        // whose choices are kept for every entry.
        Self.restore(into: self)
        remembersSettings = true
        setAccessibilityIdentifier("editor")
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Settings from Edit > Spelling and Substitutions

    private static let settings: [(key: String, get: (NSTextView) -> Bool, set: (NSTextView, Bool) -> Void)] = [
        ("editor.checkSpelling", { $0.isContinuousSpellCheckingEnabled }, { $0.isContinuousSpellCheckingEnabled = $1 }),
        ("editor.checkGrammar", { $0.isGrammarCheckingEnabled }, { $0.isGrammarCheckingEnabled = $1 }),
        ("editor.correctSpelling", { $0.isAutomaticSpellingCorrectionEnabled }, { $0.isAutomaticSpellingCorrectionEnabled = $1 }),
        ("editor.smartQuotes", { $0.isAutomaticQuoteSubstitutionEnabled }, { $0.isAutomaticQuoteSubstitutionEnabled = $1 }),
        ("editor.smartDashes", { $0.isAutomaticDashSubstitutionEnabled }, { $0.isAutomaticDashSubstitutionEnabled = $1 }),
        ("editor.textReplacement", { $0.isAutomaticTextReplacementEnabled }, { $0.isAutomaticTextReplacementEnabled = $1 }),
        ("editor.smartCopyPaste", { $0.smartInsertDeleteEnabled }, { $0.smartInsertDeleteEnabled = $1 }),
    ]

    private static func restore(into view: NSTextView) {
        for setting in settings {
            if let saved = UserDefaults.standard.object(forKey: setting.key) as? Bool { setting.set(view, saved) }
        }
    }

    private func remember() {
        guard remembersSettings else { return }
        for setting in Self.settings { UserDefaults.standard.set(setting.get(self), forKey: setting.key) }
    }

    override var isContinuousSpellCheckingEnabled: Bool { didSet { remember() } }
    override var isGrammarCheckingEnabled: Bool { didSet { remember() } }
    override var isAutomaticSpellingCorrectionEnabled: Bool { didSet { remember() } }
    override var isAutomaticQuoteSubstitutionEnabled: Bool { didSet { remember() } }
    override var isAutomaticDashSubstitutionEnabled: Bool { didSet { remember() } }
    override var isAutomaticTextReplacementEnabled: Bool { didSet { remember() } }
    override var smartInsertDeleteEnabled: Bool { didSet { remember() } }

    // MARK: The page

    /// The header sits inside the text view, where accessibility wouldn't look for its buttons.
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + (headerController.map { [$0.view] } ?? [])
    }

    func setHeader(_ header: AnyView) {
        // The header says when its height changes, so a keystroke doesn't measure it again.
        let measured = AnyView(header
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                guard let self, abs(height - self.headerHeight) > 0.5 else { return }
                self.headerHeight = height
                self.layOutPage()
            })
        if let headerController {
            headerController.rootView = measured
        } else {
            let controller = NSHostingController(rootView: measured)
            controller.sizingOptions = []
            addSubview(controller.view)
            headerController = controller
            headerHeight = controller.sizeThatFits(in: NSSize(width: Self.maxWidth, height: .greatestFiniteMagnitude)).height
            layOutPage()
        }
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if size.width != laidOutWidth { layOutPage() }
    }

    /// The inset is the same above and below, so the origin moves the text down below the header.
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: top) }

    private func layOutPage() {
        // Centred whenever there's room, with a margin that never goes below the minimum.
        let side = max(Self.margin, (bounds.width - Self.maxWidth) / 2)
        let width = min(Self.maxWidth, bounds.width - side * 2)
        guard width > 0 else { return }
        laidOutWidth = bounds.width
        textContainer?.size.width = width
        headerController?.view.frame = NSRect(x: side, y: Self.topInset, width: width, height: headerHeight)
        top = Self.topInset + headerHeight
        textContainerInset = NSSize(width: side, height: (top + Self.bottomInset) / 2)
        // All of it, or marks like a spelling underline can stay where the text used to be.
        let all = NSRange(location: 0, length: (string as NSString).length)
        layoutManager?.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        layoutManager?.invalidateDisplay(forCharacterRange: all)
        needsDisplay = true
    }

    /// View > Zoom: the size is already saved, so restyle and measure the page again.
    func textSizeChanged() {
        MarkdownStyler.style(textStorage!)
        typingAttributes = MarkdownStyler.base
        layOutPage()
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

    /// Formatting and inserted images, applied here so Undo names them.
    func run(_ command: EditorCommand) {
        guard isEditable, !hasMarkedText() else { return }
        let old = string
        let current = Range(selectedRange(), in: old).map { TextSelection(range: $0) }
        let (new, selection, name): (String, TextSelection?, String) = switch command.action {
        case .format(let format):
            { let (t, s) = format.apply(to: old, selection: current); return (t, s, format.actionName) }()
        case .insert(let snippet, let name):
            { let (t, s) = MarkdownFormat.insert(snippet, into: old, at: current); return (t, s, name) }()
        }
        replaceChanges(with: new)
        if case .selection(let range)? = selection?.indices, range.upperBound <= string.endIndex {
            setSelectedRange(NSRange(range, in: string))
        }
        undoManager?.setActionName(name)
        focusWhenReady()
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { !isLocked && super.acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { report(focus: true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { report(focus: false) }
        return resigned
    }

    /// Later, because focus can move during a SwiftUI update.
    private func report(focus: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onFocus?(focus) }
    }

    func focusWhenReady() {
        if let window, !isLocked { window.makeFirstResponder(self) } else { wantsFocus = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, wantsFocus, !isLocked {
            wantsFocus = false
            DispatchQueue.main.async { window.makeFirstResponder(self) }
        }
    }

    // MARK: Substitutions

    /// Smart dashes and quotes follow the Mac's settings, but not where they'd break Markdown:
    /// hyphens that start a line or run to three or more (a rule, front matter, a table), and
    /// anything inside code.
    override func handleTextCheckingResults(_ results: [NSTextCheckingResult], forRange range: NSRange,
                                            types checkingTypes: NSTextCheckingTypes,
                                            options: [NSSpellChecker.OptionKey: Any] = [:],
                                            orthography: NSOrthography, wordCount: Int) {
        let kept = results.filter { !keepsLiteral($0) }
        super.handleTextCheckingResults(kept, forRange: range, types: checkingTypes, options: options,
                                        orthography: orthography, wordCount: wordCount)
    }

    private func keepsLiteral(_ result: NSTextCheckingResult) -> Bool {
        guard result.resultType == .dash || result.resultType == .quote else { return false }
        let ns = string as NSString
        let found = result.range
        guard found.location != NSNotFound, NSMaxRange(found) <= ns.length else { return false }
        if isInCode(at: found.location, in: ns) { return true }
        guard result.resultType == .dash else { return false }
        let line = ns.lineRange(for: NSRange(location: found.location, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: found.location - line.location))
        if before.allSatisfy({ $0 == " " || $0 == "-" }) { return true }
        let hyphen = unichar(UInt8(ascii: "-"))
        if before.hasSuffix("-") { return true }
        return NSMaxRange(found) < ns.length && ns.character(at: NSMaxRange(found)) == hyphen
    }

    /// Inside a fence (an odd number of ``` lines above), or a code span on this line.
    private func isInCode(at location: Int, in ns: NSString) -> Bool {
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        var fences = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: line.location), options: .byLines) { text, _, _, _ in
            if text?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { fences += 1 }
        }
        if fences % 2 == 1 { return true }
        let before = ns.substring(with: NSRange(location: line.location, length: location - line.location))
        return before.filter { $0 == "`" }.count % 2 == 1
    }

    // MARK: Undo

    /// Typing steps first, then the window's: a deleted entry, a revert. Nothing while locked.
    @objc func undo(_ sender: Any?) {
        guard !isLocked else { return }
        if undoManager?.canUndo == true { undoManager?.undo() } else { window?.undoManager?.undo() }
    }

    @objc func redo(_ sender: Any?) {
        guard !isLocked else { return }
        if undoManager?.canRedo == true { undoManager?.redo() } else { window?.undoManager?.redo() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            let manager = undoManager?.canUndo == true ? undoManager : window?.undoManager
            (item as? NSMenuItem)?.title = manager?.undoMenuItemTitle ?? "Undo"
            return !isLocked && manager?.canUndo == true
        case #selector(redo(_:)):
            let manager = undoManager?.canRedo == true ? undoManager : window?.undoManager
            (item as? NSMenuItem)?.title = manager?.redoMenuItemTitle ?? "Redo"
            return !isLocked && manager?.canRedo == true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Keys

    /// Esc closes the find bar, then leaves Focus Mode, and otherwise does what it always does.
    /// While composing, the input method has it first.
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { return super.cancelOperation(sender) }
        if let scroll = enclosingScrollView, scroll.isFindBarVisible {
            let hide = NSMenuItem()
            hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performTextFinderAction(hide)
            return
        }
        if !onEscape() { super.cancelOperation(sender) }
    }

    /// ⌘S: there's no Save Draft, because writing saves itself. A local site's Save does run,
    /// and anywhere else the key just saves at once instead of beeping.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s", window?.isKeyWindow == true, !isLocked {
            onSave()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func moveUp(_ sender: Any?) {
        if let onLeaveTop, selectedRange().length == 0, isOnFirstLine { onLeaveTop() } else { super.moveUp(sender) }
    }

    private var isOnFirstLine: Bool {
        guard let layout = layoutManager else { return true }
        let length = (string as NSString).length
        let location = selectedRange().location
        guard length > 0, location > 0 else { return true }
        var line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: min(location, length - 1)), effectiveRange: nil)
        if location == length, string.hasSuffix("\n") { line = layout.extraLineFragmentRect }
        return line.minY <= layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + 0.5
    }

    /// The list item the cursor is on: its indent, marker and the line around it.
    private struct ListLine {
        let line: NSRange
        let indent: Int
        let marker: String
        let number: Int?
        let delimiter: String
        let isTask: Bool
        let isQuote: Bool
        let rest: String
    }

    private static let listItem = try! NSRegularExpression(pattern: #"^([ \t]*)(?:([-*+]) (\[[ xX]\] )?|(\d+)([.)]) |(> ))"#)

    private func listLine(at location: Int) -> ListLine? {
        let text = string as NSString
        var line = text.lineRange(for: NSRange(location: location, length: 0))
        if line.length > 0, text.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        let content = text.substring(with: line)
        guard let match = Self.listItem.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) else { return nil }
        let ns = content as NSString
        func group(_ i: Int) -> String? { match.range(at: i).location == NSNotFound ? nil : ns.substring(with: match.range(at: i)) }
        return ListLine(line: line, indent: match.range(at: 1).length, marker: ns.substring(with: match.range).dropFirst(match.range(at: 1).length).description,
                        number: group(4).flatMap(Int.init), delimiter: group(5) ?? "", isTask: group(3) != nil, isQuote: group(6) != nil,
                        rest: ns.substring(from: match.range.length))
    }

    private func replace(_ range: NSRange, with text: String, caret: Int) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Return carries a list on, numbered or not. Return on an empty item ends the list.
    override func insertNewline(_ sender: Any?) {
        let selected = selectedRange()
        guard isEditable, !hasMarkedText(), selected.length == 0, let item = listLine(at: selected.location),
              selected.location >= item.line.location + item.indent + item.marker.utf16.count else {
            return super.insertNewline(sender)
        }
        if item.rest.trimmingCharacters(in: .whitespaces).isEmpty {
            replace(item.line, with: "", caret: item.line.location)
            return
        }
        let indent = (string as NSString).substring(with: NSRange(location: item.line.location, length: item.indent))
        let marker: String = if let number = item.number { "\(number + 1)\(item.delimiter) " }
            else if item.isQuote { "> " }
            else { "\(item.marker.prefix(1)) \(item.isTask ? "[ ] " : "")" }
        insertText("\n" + indent + marker, replacementRange: selected)
    }

    /// Tab and ⇧Tab move a list item in and out. ⇧Tab elsewhere goes up to the title.
    override func insertTab(_ sender: Any?) {
        let selected = selectedRange()
        guard isEditable, !hasMarkedText(), let item = listLine(at: selected.location), !item.isQuote,
              NSMaxRange(selected) <= NSMaxRange(item.line) else { return super.insertTab(sender) }
        // The width of the parent's bullet or number; a task's box doesn't count.
        let unit = previousListLine(before: item).map { $0.marker.count - ($0.isTask ? 4 : 0) } ?? 2
        let spaces = String(repeating: " ", count: max(unit, 2))
        replace(NSRange(location: item.line.location, length: 0), with: spaces, caret: selected.location + spaces.count)
    }

    override func insertBacktab(_ sender: Any?) {
        let selected = selectedRange()
        guard isEditable, !hasMarkedText(), let item = listLine(at: selected.location), !item.isQuote, item.indent > 0 else {
            if let onLeaveTop { onLeaveTop() } else { super.insertBacktab(sender) }
            return
        }
        // Back to the level of the item it sat under, or the margin.
        var target = 0
        var location = item.line.location
        while location > 0, let previous = listLine(at: location - 1) {
            if previous.indent < item.indent { target = previous.indent; break }
            location = previous.line.location
        }
        let removed = item.indent - target
        replace(NSRange(location: item.line.location, length: removed), with: "", caret: max(item.line.location, selected.location - removed))
    }

    private func previousListLine(before item: ListLine) -> ListLine? {
        item.line.location > 0 ? listLine(at: item.line.location - 1) : nil
    }

    // MARK: Context menu

    /// Only what plain Markdown can use: no fonts, writing direction or layout orientation.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let unwanted: Set<String> = [
            "orderFrontFontPanel:", "addFontTrait:", "underline:", "changeLayoutOrientation:",
            "makeBaseWritingDirectionNatural:", "makeBaseWritingDirectionLeftToRight:", "makeBaseWritingDirectionRightToLeft:",
            "makeTextWritingDirectionNatural:", "makeTextWritingDirectionLeftToRight:", "makeTextWritingDirectionRightToLeft:",
            "toggleQuickLookPreviewPanel:", "orderFrontSubstitutionsPanel:",
        ]
        func isUnwanted(_ item: NSMenuItem) -> Bool {
            if let action = item.action, unwanted.contains(NSStringFromSelector(action)) { return true }
            return item.submenu?.items.contains(where: isUnwanted) == true
        }
        for item in menu.items where isUnwanted(item) { menu.removeItem(item) }
        if isEditable, let paste = menu.items.firstIndex(where: { $0.action == #selector(paste(_:)) }) {
            let after = menu.items[paste...].firstIndex(where: \.isSeparatorItem) ?? menu.items.count
            let items: [NSMenuItem] = [
                .separator(),
                NSMenuItem(title: "Bold", action: #selector(formatBold), keyEquivalent: ""),
                NSMenuItem(title: "Italic", action: #selector(formatItalic), keyEquivalent: ""),
                NSMenuItem(title: "Link", action: #selector(formatLink), keyEquivalent: ""),
            ]
            for (offset, item) in items.enumerated() {
                item.target = self
                menu.insertItem(item, at: after + offset)
            }
        }
        // No separators left doubled up, or at either end.
        var lastWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, lastWasSeparator { menu.removeItem(item) } else { lastWasSeparator = item.isSeparatorItem }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    @objc private func formatBold() { onFormat?(.bold) }
    @objc private func formatItalic() { onFormat?(.italic) }
    @objc private func formatLink() { onFormat?(.link) }

    // MARK: Images

    /// A plain text view only reads text, which would leave Paste off for a bare screenshot.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        // An image file copied in Finder comes with its name as text, so files go first. Then
        // text wins: copying from a web page often carries a picture of itself too.
        let files = Self.imageFiles(on: board)
        if !files.isEmpty {
            onImages?(files.compactMap { try? Data(contentsOf: $0) })
        } else if board.string(forType: .string) == nil, let image = Self.imageData(on: board) {
            onImages?([image])
        } else {
            super.paste(sender)
        }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isLocked { return [] }
        return Self.carriesImages(sender) ? imageDrop : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isLocked { return [] }
        return Self.carriesImages(sender) ? imageDrop : super.draggingUpdated(sender)
    }

    private var imageDrop: NSDragOperation { isEditable ? .copy : [] }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isLocked { return false }
        guard Self.carriesImages(sender) else { return super.performDragOperation(sender) }
        guard isEditable else { return false }
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
        let board = sender.draggingPasteboard
        let files = Self.imageFiles(on: board)
        if !files.isEmpty {
            onImages?(files.compactMap { try? Data(contentsOf: $0) })
        } else if let image = Self.imageData(on: board) {
            onImages?([image])
        } else {
            receivePromises(from: sender)
        }
        return true
    }

    /// Photos, Safari and others promise a file and write it once the drop lands.
    /// All of them arrive together, as one batch, however many were dropped.
    private func receivePromises(from sender: any NSDraggingInfo) {
        guard let folder = try? TransferFolder.make() else { return }
        let batch = PromisedImages()
        let group = DispatchGroup()
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSFilePromiseReceiver.self], searchOptions: [:]) { item, _, _ in
            guard let receiver = item.item as? NSFilePromiseReceiver, Self.isImage(receiver) else { return }
            // The reader runs once for each promised file, whether it arrived or not.
            for _ in receiver.fileTypes { group.enter() }
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                let data = error == nil ? try? Data(contentsOf: url) : nil
                MainActor.assumeIsolated {
                    if let data { batch.images.append(data) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.onImages?(batch.images) }
        }
    }

    private final class PromisedImages {
        var images: [Data] = []
    }

    private static func isImage(_ receiver: NSFilePromiseReceiver) -> Bool {
        receiver.fileTypes.contains { UTType($0)?.conforms(to: .image) == true }
    }

    private static func carriesImages(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if !imageFiles(on: board).isEmpty { return true }
        // Dragged text can carry a picture of itself; dragged pictures don't carry HTML.
        let types = board.types ?? []
        if board.availableType(from: [.png, .tiff]) != nil, !types.contains(.html), !types.contains(.rtf) { return true }
        let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        return promises.contains(where: isImage)
    }

    private static func imageFiles(on board: NSPasteboard) -> [URL] {
        board.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
    }

    private static func imageData(on board: NSPasteboard) -> Data? {
        board.data(forType: .png) ?? board.data(forType: .tiff)
    }
}
