import AppKit
import SwiftData
import SwiftUI

struct MacRootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(MacWindowState.self) private var window
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: Site.order) private var sites: [Site]
    /// Only IDs and names of columns: the app's own state stays in its own locked-down store.
    @SceneStorage("selectedEntry") private var restoredEntry = ""
    @SceneStorage("sidebarItem") private var restoredSidebar = ""
    @SceneStorage("columns") private var restoredColumns = ""
    /// What the columns were before the window got too narrow for them.
    @State private var columnsBeforeNarrowing: NavigationSplitViewVisibility?

    var body: some View {
        // Locked, the window is covered rather than emptied, so the page, the cursor, the scroll
        // position and Undo are all still there after unlocking.
        ZStack {
            content
                .opacity(lock.isUnlocked ? 1 : 0)
                .allowsHitTesting(lock.isUnlocked)
                .accessibilityHidden(!lock.isUnlocked)
                .disabled(!lock.isUnlocked)
            // Focus Mode: the page alone over the whole window. The columns underneath are left
            // as they are, so there's nothing to put back afterwards.
            if window.isFocused && lock.isUnlocked && !sites.isEmpty {
                FocusPage()
            }
            if !lock.isUnlocked {
                // Replaces the entry's title, which is otherwise left in the title bar.
                LockView().navigationTitle("Quill")
            }
        }
        .background {
            WindowBridge(isLocked: !lock.isUnlocked, isFocused: window.isFocused,
                         fadesTitlebar: window.isFocused && !window.focusChromeShown,
                         showsSidebarToggle: lock.isUnlocked && !sites.isEmpty, toggleSidebar: toggleSidebar,
                         pointerMoved: { window.pointerMoved(to: $0, inTitleBar: $1) },
                         leaveFocus: { window.exitFocus() })
        }
        .background { AttentionWatcher() }
        // Closing the window ends Focus Mode, so reopening it shows the window as it was.
        .onDisappear { window.exitFocus() }
        .onChange(of: lock.isUnlocked) { _, isUnlocked in
            if !isUnlocked { window.exitFocus() }
            // Nothing stays open over the lock: sheets and dialogs name sites and show writing.
            if !isUnlocked {
                navigation.showingAddSite = false
                window.showingImporter = false
                window.editingSite = nil
                window.removingSite = nil
            }
            if isUnlocked { Task { await publisher.flushOutbox() } }
        }
        .onChange(of: sites.isEmpty, initial: true) { _, isEmpty in window.hasSites = !isEmpty }
        .onChange(of: sites.isEmpty) { _, isEmpty in
            if !isEmpty { navigation.openBlankEntry(in: context) }
        }
        .onChange(of: sites.map(\.name), initial: true) {
            window.siteList = sites.map { ($0.id, $0.name) }
        }
        .onAppear {
            MacAppDelegate.openMainWindow = { openWindow(id: "main") }
        }
    }

    /// The same as View > Show Sidebar and ⌃⌘S.
    private func toggleSidebar() { window.toggleSidebar(navigation) }

    @ViewBuilder private var content: some View {
        if sites.isEmpty {
            MacWelcomeView()
        } else {
            splitView
        }
    }

    private var presentedSplitView: some View {
        @Bindable var navigation = navigation
        @Bindable var window = window
        return NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
            // Sizes like Mail's and Notes'. The frame enforces the minimum, which the column width
            // alone doesn't.
            MacSidebar()
                // Quill's own toggle stays put beside the traffic lights instead; see `WindowBridge`.
                .toolbar(removing: .sidebarToggle)
                .frame(minWidth: Self.sidebarWidth.min, idealWidth: Self.sidebarWidth.ideal)
                .navigationSplitViewColumnWidth(min: Self.sidebarWidth.min, ideal: Self.sidebarWidth.ideal, max: Self.sidebarWidth.max)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { window.sidebarWidth = $0 }
        } content: {
            MacContentColumn()
                .environment(\.listQuery, window.searchText)
                .environment(\.isCovered, !lock.isUnlocked)
                .environment(\.hidesTitle, window.isFocused)
                .frame(minWidth: Self.listWidth.min, idealWidth: Self.listWidth.ideal)
                .navigationSplitViewColumnWidth(min: Self.listWidth.min, ideal: Self.listWidth.ideal, max: Self.listWidth.max)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { window.listWidth = $0 }
                .toolbar {
                    // Locked or in Focus Mode, the toolbar is emptied rather than hidden; see `WindowBridge`.
                    if lock.isUnlocked && !window.isFocused {
                        ToolbarItem(placement: .primaryAction) {
                            Button { navigation.openBlankEntry(in: context) } label: {
                                Label("New Entry", systemImage: "square.and.pencil")
                            }
                            .help("New Entry (⌘N)")
                            .accessibilityIdentifier("newEntryButton")
                        }
                    }
                }
        } detail: {
            MacDetailColumn()
        }
        .sheet(isPresented: $navigation.showingAddSite) { MacAddSiteSheet() }
        .modifier(SiteEditing())
        .fileImporter(isPresented: $window.showingImporter, allowedContentTypes: MarkdownFile.openableTypes,
                      allowsMultipleSelection: true) { result in
            guard let urls = try? result.get() else { return }
            openDrafts(urls)
        }
        .task(id: lock.isUnlocked, priority: .utility) { await publisher.preloadPosts() }
    }

    /// What follows the window's state, apart from the split view itself, so each stays small
    /// enough to type-check.
    private var splitView: some View {
        presentedSplitView
        .onChange(of: sites.count) {
            repairSidebar()
            if navigation.selectedEntry == nil { navigation.openBlankEntry(in: context, focus: false) }
        }
        .onChange(of: navigation.selectedEntry) { _, entry in
            restoredEntry = entry?.id.uuidString ?? ""
        }
        .onChange(of: navigation.sidebar) { _, item in restoredSidebar = Self.encode(item) }
        .onChange(of: navigation.columnVisibility) { _, columns in
            if columnsBeforeNarrowing == nil { restoredColumns = Self.encode(columns) }
        }
        .onChange(of: widthClass) { old, new in fitColumns(from: old, to: new) }
        // Opened files wait while locked, or until the window first appears; see `MacAppDelegate`.
        .onChange(of: lock.isUnlocked, initial: true) { _, unlocked in
            if unlocked { MacAppDelegate.openFiles = { openDrafts($0) } } else { MacAppDelegate.openFiles = nil }
        }
        .onDisappear { MacAppDelegate.openFiles = nil }
        .onAppear {
            restoreColumns()
            navigation.sidebar = Self.decode(restoredSidebar) ?? navigation.sidebar
            repairSidebar()
            restoreEntry()
            let openSite: UUID? = navigation.selectedEntry?.siteID
            if !sites.contains(where: { $0.id == openSite }) {
                navigation.openBlankEntry(in: context)
            }
        }
    }

    // MARK: Columns

    static let sidebarWidth = (min: 220.0, ideal: 260.0, max: 360.0)
    static let listWidth = (min: 300.0, ideal: 380.0, max: 560.0)

    /// 0 leaves room for the list and the page, 1 for the sidebar too. The list and the page
    /// alone fit the window's minimum width.
    private var widthClass: Int {
        navigation.windowWidth < Self.sidebarWidth.ideal + Self.listWidth.ideal + 280 ? 0 : 1
    }

    /// The sidebar folds away as the window narrows, and comes back as it widens.
    private func fitColumns(from old: Int, to new: Int) {
        if new < old {
            guard navigation.columnVisibility == .all else { return }
            columnsBeforeNarrowing = .all
            withAnimation { navigation.columnVisibility = .doubleColumn }
        } else if let before = columnsBeforeNarrowing {
            columnsBeforeNarrowing = nil
            withAnimation { navigation.columnVisibility = before }
        }
    }

    private func restoreColumns() {
        switch restoredColumns {
        case "doubleColumn": navigation.columnVisibility = .doubleColumn
        case "detailOnly": navigation.columnVisibility = .detailOnly
        default: break
        }
    }

    private static func encode(_ columns: NavigationSplitViewVisibility) -> String {
        switch columns {
        case .doubleColumn: "doubleColumn"
        case .detailOnly: "detailOnly"
        default: "all"
        }
    }

    private static func encode(_ item: SidebarItem?) -> String {
        switch item {
        case .drafts?: "drafts"
        case .outbox?: "outbox"
        case .site(let id)?: id.uuidString
        case nil: ""
        }
    }

    private static func decode(_ raw: String) -> SidebarItem? {
        switch raw {
        case "drafts": .drafts
        case "outbox": .outbox
        default: UUID(uuidString: raw).map { .site($0) }
        }
    }

    // MARK: Entries

    /// Back to the entry that was open when Quill last quit, with the cursor in it.
    private func restoreEntry() {
        guard navigation.selectedEntry == nil, let id = UUID(uuidString: restoredEntry),
              let entry = try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.id == id })).first else { return }
        navigation.focusNextEntry = entry.state == .editing
        navigation.selectedEntry = entry
    }

    private func repairSidebar() {
        if case .site(let id)? = navigation.sidebar, sites.contains(where: { $0.id == id }) { return }
        if case .drafts? = navigation.sidebar { return }
        if case .outbox? = navigation.sidebar { return }
        navigation.sidebar = sites.first.map { .site($0.id) }
    }

    /// Markdown files opened, dropped on the Dock or chosen with File > Open become drafts.
    private func openDrafts(_ urls: [URL]) {
        let made = MarkdownFile.makeDrafts(from: urls, in: context, siteID: navigation.defaultSiteID(in: context))
        guard let first = made.first else { return }
        navigation.sidebar = .drafts
        navigation.show(first)
    }
}

/// The badge and failure notice follow the store, in a view of their own so writing doesn't
/// redraw the window around them.
private struct AttentionWatcher: View {
    @Environment(MacWindowState.self) private var window
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Entry> { $0.stateRaw == "failed" }) private var failed: [Entry]

    var body: some View {
        Color.clear
            .onChange(of: failed.count, initial: true) { _, count in
                window.hasFailures = count > 0
                Attention.update(context)
            }
    }
}

/// What only the window itself can do: keep the keyboard off the page while it's covered, in
/// Focus Mode hide the title and fade the title bar's buttons, and hold the sidebar toggle.
private struct WindowBridge: NSViewRepresentable {
    let isLocked: Bool
    let isFocused: Bool
    let fadesTitlebar: Bool
    let showsSidebarToggle: Bool
    let toggleSidebar: () -> Void
    /// Focus Mode's pointer, from anywhere in the window: where it is, and whether that's the title bar.
    let pointerMoved: (NSPoint, Bool) -> Void
    let leaveFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = LockResponder()
        context.coordinator.lockResponder = view
        return view
    }

    /// Holds the keyboard while the window is locked, so nothing behind the cover gets it, and
    /// turns down Undo and Redo, which would otherwise reach the window's steps.
    final class LockResponder: NSView, NSMenuItemValidation {
        var isHolding = false
        override var acceptsFirstResponder: Bool { isHolding }
        @objc func undo(_ sender: Any?) {}
        @objc func redo(_ sender: Any?) {}
        /// Only Undo and Redo come here, and both stay off.
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { false }
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.toggleSidebar = toggleSidebar
        coordinator.pointerMoved = pointerMoved
        coordinator.leaveFocus = leaveFocus
        let (isLocked, isFocused, fades, showsToggle) = (isLocked, isFocused, fadesTitlebar, showsSidebarToggle)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            coordinator.update(window, isLocked: isLocked, isFocused: isFocused, fadesTitlebar: fades)
            coordinator.showToggle(showsToggle, in: window)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeToggle()
        coordinator.stopWatching()
    }

    final class Coordinator {
        var toggleSidebar: () -> Void = {}
        var pointerMoved: (NSPoint, Bool) -> Void = { _, _ in }
        var leaveFocus: () -> Void = {}
        weak var lockResponder: LockResponder?
        private weak var repairedSplit: NSSplitViewController?
        private var accessory: NSTitlebarAccessoryViewController?
        private var wasLocked = false
        private var wasFocused = false
        private var wasFaded = false
        private weak var responder: NSResponder?
        private var monitor: Any?
        private var acceptedMouseMoves = false

        func update(_ window: NSWindow, isLocked: Bool, isFocused: Bool, fadesTitlebar: Bool) {
            sizeColumnsOnce(in: window)
            repairNewSplitView(in: window)
            if isFocused != wasFocused {
                wasFocused = isFocused
                // The page covers the window, so the title goes and the title bar shows the page,
                // keeping the traffic lights and the toggle. The toolbar stays, emptied by the
                // columns (see `MacEditorView`): hidden and shown again, SwiftUI grows the window by
                // the toolbar's height on every layout, up to the height of the screen. The lock
                // empties it the same way, so nothing there names a site or an entry.
                window.titleVisibility = isFocused ? .hidden : .visible
                window.titlebarAppearsTransparent = isFocused
                if isFocused {
                    watch(window)
                } else {
                    stopWatching(window)
                    // With the title back, it's laid out from scratch and lands under the toggle.
                    // Putting the toggle back afterwards makes room for it again.
                    DispatchQueue.main.async { [weak self, weak window] in
                        guard let self, let window, !self.wasFocused, let accessory = self.accessory,
                              let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) else { return }
                        window.removeTitlebarAccessoryViewController(at: index)
                        window.addTitlebarAccessoryViewController(accessory)
                    }
                }
            }
            if isLocked != wasLocked {
                wasLocked = isLocked
                if isLocked {
                    endAppKitSheets(on: window)
                    // A field's editor stands in for the field, so keep the field.
                    let current = window.firstResponder
                    responder = (current as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : nil } ?? current
                    lockResponder?.isHolding = true
                    if window.makeFirstResponder(lockResponder) == false { window.makeFirstResponder(nil) }
                } else {
                    lockResponder?.isHolding = false
                    if let view = responder as? NSView, view.window === window {
                        window.makeFirstResponder(view)
                    } else if window.firstResponder === lockResponder {
                        window.makeFirstResponder(nil)
                    }
                }
            }
            if fadesTitlebar != wasFaded {
                wasFaded = fadesTitlebar
                let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
                let faded = buttons + [accessory?.view].compactMap(\.self)
                // Hidden once they've faded, so a click where they were does nothing.
                if !fadesTitlebar { for view in faded { view.isHidden = false } }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    for view in faded { view.animator().alphaValue = fadesTitlebar ? 0 : 1 }
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.wasFaded == fadesTitlebar, fadesTitlebar else { return }
                        for view in faded { view.isHidden = true }
                    }
                }
            }
        }

        /// Nothing stays open over the lock. SwiftUI's own sheets and dialogs close by their state
        /// (see `MacRootView`); AppKit's (the print panel, Export's save panel) are ended here.
        /// A sheet SwiftUI hosts is left to SwiftUI, so the two never close the same one.
        private func endAppKitSheets(on window: NSWindow) {
            for sheet in window.sheets.reversed() where !Self.isSwiftUISheet(sheet) {
                window.endSheet(sheet, returnCode: .cancel)
            }
        }

        private static func isSwiftUISheet(_ sheet: NSWindow) -> Bool {
            let hosting = [sheet.contentViewController.map { NSStringFromClass(type(of: $0)) },
                           sheet.contentView.map { NSStringFromClass(type(of: $0)) }]
            return hosting.contains { $0?.contains("Hosting") == true }
        }

        /// Focus Mode's one source of pointer moves and its Esc, for the whole window, title bar
        /// included. Esc in a text view (the page, the title, the find bar) is that view's to
        /// handle, so composing and completion keep it; anywhere else, it leaves Focus Mode.
        private func watch(_ window: NSWindow) {
            stopWatching(window)
            acceptedMouseMoves = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self, weak window] event in
                guard let self, let window, event.window === window else { return event }
                switch event.type {
                case .mouseMoved:
                    let point = event.locationInWindow
                    self.pointerMoved(NSEvent.mouseLocation, point.y >= window.contentLayoutRect.maxY - 8)
                    return event
                case .keyDown where event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
                    guard window.attachedSheet == nil, !(window.firstResponder is NSTextView) else { return event }
                    self.leaveFocus()
                    return nil
                default:
                    return event
                }
            }
        }

        func stopWatching(_ window: NSWindow? = nil) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let window { window.acceptsMouseMovedEvents = acceptedMouseMoves }
        }

        /// The sidebar toggle sits right after the traffic lights, and stays there whether the
        /// sidebar is open or not. The system's own rides along with the sidebar's edge.
        func showToggle(_ isShown: Bool, in window: NSWindow) {
            if accessory == nil, isShown {
                let button = Button { [weak self] in self?.toggleSidebar() } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Show or Hide Sidebar (⌃⌘S)")
                .accessibilityLabel("Toggle Sidebar")
                .accessibilityIdentifier("sidebarToggle")
                .padding(.horizontal, 6)
                let host = NSHostingView(rootView: button)
                host.frame.size = host.fittingSize
                let controller = NSTitlebarAccessoryViewController()
                controller.view = host
                controller.layoutAttribute = .leading
                window.addTitlebarAccessoryViewController(controller)
                accessory = controller
            }
            let hides = !isShown || wasFaded
            accessory?.isHidden = hides
            // With the toolbar left in place over the lock, the controller's flag alone leaves the
            // button showing, so the view goes too.
            accessory?.view.isHidden = hides
        }

        func removeToggle() {
            accessory?.removeFromParent()
            accessory = nil
        }

        /// Earlier builds folded the list for Focus Mode through AppKit, and the split view saves
        /// its frames, folds included, so a Mac may still have a folded or 800-point list saved.
        /// Each new split view is checked once it's laid out, and put right if it's out of bounds.
        private func repairNewSplitView(in window: NSWindow) {
            guard let split = Self.splitController(in: window.contentView),
                  split.splitViewItems.count == 3, repairedSplit !== split else { return }
            repairedSplit = split
            DispatchQueue.main.async { Self.repair(split) }
        }

        private static func repair(_ split: NSSplitViewController) {
            guard split.splitViewItems.count == 3 else { return }
            if split.splitViewItems[1].isCollapsed { split.splitViewItems[1].isCollapsed = false }
            let widths = split.splitView.arrangedSubviews.map(\.frame.width)
            guard widths.count == 3 else { return }
            let sidebarShown = !split.splitViewItems[0].isCollapsed
            let sidebarRange = MacRootView.sidebarWidth.min - 1...MacRootView.sidebarWidth.max + 1
            let listRange = MacRootView.listWidth.min - 1...MacRootView.listWidth.max + 1
            guard (sidebarShown && !sidebarRange.contains(widths[0])) || !listRange.contains(widths[1]) else { return }
            let divider = split.splitView.dividerThickness
            var listStart: CGFloat = 0
            if sidebarShown {
                let sidebar = min(max(widths[0], MacRootView.sidebarWidth.min), MacRootView.sidebarWidth.max)
                split.splitView.setPosition(sidebar, ofDividerAt: 0)
                listStart = sidebar + divider
            }
            let list = listRange.contains(widths[1]) ? widths[1] : MacRootView.listWidth.ideal
            split.splitView.setPosition(listStart + list, ofDividerAt: 1)
        }

        /// The split view opens at its minimums the first time, then keeps whatever it's dragged to.
        /// So the first time, the columns start at their ideal widths.
        private func sizeColumnsOnce(in window: NSWindow) {
            let key = "sizedColumns"
            guard !UserDefaults.standard.bool(forKey: key), let split = Self.splitController(in: window.contentView),
                  split.splitViewItems.count == 3, !split.splitViewItems[0].isCollapsed, !split.splitViewItems[1].isCollapsed,
                  window.frame.width >= MacRootView.sidebarWidth.ideal + MacRootView.listWidth.ideal + 280 else { return }
            UserDefaults.standard.set(true, forKey: key)
            let divider = split.splitView.dividerThickness
            split.splitView.setPosition(MacRootView.sidebarWidth.ideal, ofDividerAt: 0)
            split.splitView.setPosition(MacRootView.sidebarWidth.ideal + divider + MacRootView.listWidth.ideal, ofDividerAt: 1)
        }

        private static func splitController(in view: NSView?) -> NSSplitViewController? {
            guard let view else { return nil }
            if let split = (view as? NSSplitView)?.delegate as? NSSplitViewController { return split }
            return view.subviews.lazy.compactMap(splitController).first
        }
    }
}

/// Focus Mode over the window: paper, the lent page, and a word on how to leave.
private struct FocusPage: View {
    @Environment(MacWindowState.self) private var window
    @State private var showsHint = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.paper
            FocusSurface(stage: window.focusStage, generation: window.focusStage.generation)
            if showsHint {
                Text("Press Esc to leave Focus Mode")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { showsHint = false }
        }
    }
}

/// Focus Mode's page: the editor's own scroll view and text view, lent to a surface over the
/// whole window and given back on leaving, so the caret, selection, scroll and Undo all carry
/// over. The columns behind it stay exactly as they were.
private struct FocusSurface: NSViewRepresentable {
    let stage: FocusStage
    /// Read so a new page (⌘N while focused) is adopted.
    let generation: Int

    func makeNSView(context: Context) -> FocusSurfaceView { FocusSurfaceView(stage: stage) }
    func updateNSView(_ view: FocusSurfaceView, context: Context) {
        let page = stage.page
        DispatchQueue.main.async { view.adopt(page) }
    }
    static func dismantleNSView(_ view: FocusSurfaceView, coordinator: ()) { view.giveBack() }
}

final class FocusSurfaceView: NSView {
    private weak var stage: FocusStage?
    private weak var page: MacPageHost?
    /// Once leaving has given the page back, a late update mustn't borrow it again.
    private var isReleased = false

    init(stage: FocusStage) {
        self.stage = stage
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func adopt(_ new: MacPageHost?) {
        guard !isReleased, new !== page else { return }
        page?.reclaim()
        page = new
        guard let new else { return }
        new.lend(to: self)
        // Whatever had the keyboard (the sidebar, the list), the page has it now, so typing and
        // Esc work straight away.
        new.textView?.focusWhenReady()
    }

    func giveBack() {
        isReleased = true
        guard let page else { return }
        // Leaving recorded it (see `MacWindowState.exitFocus`): this view is out of the window by now.
        let hadKeyboard = stage?.returnsKeyboard == true || page.textView.map { window?.firstResponder === $0 } == true
        stage?.returnsKeyboard = false
        page.reclaim()
        self.page = nil
        if hadKeyboard { page.textView?.focusWhenReady() }
    }
}

private struct MacContentColumn: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        switch navigation.sidebar {
        case .site(let id): SitePostsView(siteID: id).id(id)
        case let item?: EntryListView(section: item)
        case nil: ContentUnavailableView("Nothing selected", systemImage: "sidebar.left")
        }
    }
}

private struct MacDetailColumn: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.modelContext) private var context

    var body: some View {
        if let entry = navigation.selectedEntry, entry.modelContext != nil, !entry.isDeleted {
            MacEditorView(entry: entry)
                .id(entry.id)
        } else {
            ContentUnavailableView {
                Label("No entry selected", systemImage: "square.and.pencil")
            } actions: {
                Button("New Entry") { navigation.openBlankEntry(in: context) }
            }
        }
    }
}
