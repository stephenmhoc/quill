import AppKit
import SwiftData
import SwiftUI

@main
struct QuillMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    private let container: ModelContainer
    private let lifecycle: MacLifecycle
    @State private var lock: AppLock
    @State private var navigation = Navigation()
    @State private var window = MacWindowState()
    @State private var publisher: Publisher
    @AppStorage(Appearance.key) private var appearance = Appearance.auto

    init() {
        Telemetry.start()
        Updates.start()
        let container = QuillStore.makeContainer()
        let lock = AppLock()
        #if DEBUG
        if CommandLine.arguments.contains("-skipUnlock") { lock.unlockForTesting(keys: [:]) }
        #endif
        let publisher = Publisher(lock: lock, context: container.mainContext)
        self.container = container
        lifecycle = MacLifecycle(lock: lock, publisher: publisher, context: container.mainContext)
        _lock = State(initialValue: lock)
        _publisher = State(initialValue: publisher)
    }

    var body: some Scene {
        // One window: a journal is one place. Closing it leaves Quill running, with the outbox
        // still sending, until it's quit.
        Window("Quill", id: "main") {
            MacRootView()
                .environment(lock)
                .environment(navigation)
                .environment(window)
                .environment(publisher)
                .frame(minWidth: 600, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { navigation.windowWidth = $0 }
                .onChange(of: appearance, initial: true) { _, choice in
                    NSApp.appearance = choice.colorScheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) } ?? nil
                }
                .onAppear {
                    MacAppDelegate.newEntry = {
                        guard lock.isUnlocked, window.hasSites else { return }
                        navigation.openBlankEntry(in: container.mainContext)
                    }
                }
        }
        .modelContainer(container)
        .defaultSize(width: 1320, height: 820)
        .commands { MacCommands(navigation: navigation, window: window, lock: lock, publisher: publisher, context: container.mainContext) }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            MacSettingsView()
                .environment(lock)
                .modelContainer(container)
        }
    }
}

/// What has to happen whether or not the window is open: locking, saving, and the outbox.
@MainActor
final class MacLifecycle {
    private var observers: [NSObjectProtocol] = []

    init(lock: AppLock, publisher: Publisher, context: ModelContext) {
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            })
        }
        let lockNow: @MainActor () -> Void = {
            try? context.save()
            lock.lock()
        }
        observe(app, NSApplication.didResignActiveNotification) {
            lock.didResignActive()
            try? context.save()
        }
        observe(app, NSApplication.didBecomeActiveNotification) { lock.didBecomeActive() }
        observe(app, NSApplication.willTerminateNotification) { try? context.save() }
        // Stepping away from the Mac is a stronger signal than switching apps, so no grace here.
        observe(workspace, NSWorkspace.screensDidSleepNotification, lockNow)
        observe(workspace, NSWorkspace.willSleepNotification, lockNow)
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lockNow() }
            })
        // Retry queued entries every minute, for as long as Quill runs.
        Task {
            while !Task.isCancelled {
                await publisher.flushOutbox()
                Attention.update(context)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the window, which knows whether there's anywhere to write yet.
    static var newEntry: (() -> Void)?
    static var openMainWindow: (() -> Void)?
    /// Set by the window while it's unlocked. Files that arrive before then wait for it.
    static var openFiles: (([URL]) -> Void)? { didSet { openPendingFiles() } }
    private static var pendingFiles: [URL] = []

    private static func openPendingFiles() {
        guard let openFiles, !pendingFiles.isEmpty else { return }
        let urls = pendingFiles
        pendingFiles = []
        openFiles(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) { TransferFolder.clear() }
    func applicationWillTerminate(_ notification: Notification) { TransferFolder.clear() }

    /// The outbox keeps going with the window closed, and Quill quits only when asked to.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with the window closed opens it again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openMainWindow?() }
        return true
    }

    /// Markdown files opened from Finder or dropped on the Dock icon become drafts.
    func application(_ application: NSApplication, open urls: [URL]) {
        // At launch the window isn't there yet, and while locked they'd land behind the lock.
        Self.pendingFiles += urls
        Self.openMainWindow?()
        DispatchQueue.main.async { Self.openPendingFiles() }
    }

    /// The Dock icon's menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Entry", action: #selector(newEntry), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newEntry() {
        NSApp.activate()
        Self.openMainWindow?()
        Self.newEntry?()
    }
}

/// What the menu bar can do to whichever entry is open.
struct EditorActions {
    let canPublish: Bool
    let canPreview: Bool
    /// The window has to be wide enough for the text and the page side by side.
    let canShowPreview: Bool
    let canEdit: Bool
    /// Formatting needs a selection, and only the body's is one it can use.
    let canFormat: Bool
    let hasTitle: Bool
    let isPreviewing: Bool
    let publishLabel: String
    let publish: () -> Void
    let format: (MarkdownFormat) -> Void
    let togglePreview: () -> Void
    let print: () -> Void
    let toggleTitle: () -> Void
    let chooseImage: () -> Void
    let canBeginEditing: Bool
    let canRevert: Bool
    let canViewOnSite: Bool
    let beginEditing: () -> Void
    let revert: () -> Void
    let viewOnSite: () -> Void
    let showTags: () -> Void
    let canMove: Bool
    let siteID: UUID?
    let moveTo: (UUID) -> Void
    let copyLink: () -> Void
    let export: () -> Void
    let canDelete: Bool
    let delete: () -> Void
}

extension FocusedValues {
    @Entry var editorActions: EditorActions?
}

struct MacCommands: Commands {
    let navigation: Navigation
    let window: MacWindowState
    let lock: AppLock
    let publisher: Publisher
    let context: ModelContext
    @FocusedValue(\.editorActions) private var focusedEditor
    @AppStorage(MarkdownStyler.textSizeKey) private var textSize = MarkdownStyler.defaultTextSize
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    /// Nothing reaches the entry behind the lock screen.
    private var editor: EditorActions? { lock.isUnlocked ? focusedEditor : nil }
    private var canWrite: Bool { lock.isUnlocked && window.hasSites }
    private var selectedSite: Site? {
        guard case .site(let id)? = navigation.sidebar else { return nil }
        return try? context.fetch(FetchDescriptor<Site>(predicate: #Predicate { $0.id == id })).first
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updates.check() }
                .disabled(!Updates.canCheck)
        }
        // Quill's own, so it leaves Focus Mode instead of folding columns under the page.
        CommandGroup(replacing: .sidebar) {
            Button(navigation.columnVisibility == .all && !window.isFocused ? "Hide Sidebar" : "Show Sidebar") {
                window.toggleSidebar(navigation)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(!canWrite)
        }
        TextEditingCommands()
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { NSApp.runPageLayout(nil) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print…") { editor?.print() }
                .keyboardShortcut("p")
                .disabled(editor?.canPreview != true)
        }
        CommandGroup(replacing: .newItem) {
            // With the window closed these would happen out of sight, so it opens first.
            Button("New Entry") {
                openWindow(id: "main")
                navigation.openBlankEntry(in: context)
            }
                .keyboardShortcut("n")
                .disabled(!canWrite)
            Button("Open…") {
                openWindow(id: "main")
                window.showingImporter = true
            }
                .keyboardShortcut("o")
                .disabled(!canWrite)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Add Site…") { navigation.showingAddSite = true }
                .disabled(!canWrite)
            Button("Edit Site…") { window.editingSite = selectedSite }
                .disabled(!lock.isUnlocked || selectedSite == nil)
            Button("Remove Site…") { window.removingSite = selectedSite }
                .disabled(!lock.isUnlocked || selectedSite == nil)
            Divider()
            Button("Export as Markdown…") { editor?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor?.canPreview != true)
        }
        CommandMenu("Entry") {
            // Edit takes Publish's place, as it does in the toolbar, and so takes its key.
            if editor?.canBeginEditing == true {
                Button("Edit") { editor?.beginEditing() }
                    .keyboardShortcut(.return)
            } else {
                Button(editor?.publishLabel ?? "Publish") { editor?.publish() }
                    .keyboardShortcut(.return)
                    .disabled(editor?.canPublish != true)
            }
            Button("Revert to Published…") { editor?.revert() }
                .disabled(editor?.canRevert != true)
            Divider()
            Button("View on Site") { editor?.viewOnSite() }
                .disabled(editor?.canViewOnSite != true)
            Button("Copy Link") { editor?.copyLink() }
                .disabled(editor?.canViewOnSite != true)
            Divider()
            Button("Tags…") { editor?.showTags() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(editor?.canEdit != true)
            Menu("Move to Site") {
                ForEach(window.siteList, id: \.id) { site in
                    Toggle(isOn: Binding(get: { editor?.siteID == site.id }, set: { if $0 { editor?.moveTo(site.id) } })) {
                        Text(site.name)
                    }
                }
            }
            .disabled(editor?.canMove != true)
            Divider()
            Button("Retry All") { Task { await publisher.retryAll() } }
                .disabled(!lock.isUnlocked || !window.hasFailures)
            Divider()
            Button("Delete") { editor?.delete() }
                .disabled(editor?.canDelete != true)
        }
        CommandMenu("Format") {
            Group {
                Button("Bold") { editor?.format(.bold) }.keyboardShortcut("b")
                Button("Italic") { editor?.format(.italic) }.keyboardShortcut("i")
                Button("Link") { editor?.format(.link) }.keyboardShortcut("k")
                Divider()
                Menu("Heading") {
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") { editor?.format(.headingLevel(level)) }
                            .keyboardShortcut(KeyEquivalent(Character("\(level)")))
                    }
                }
                Button("List") { editor?.format(.bullet) }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("Quote") { editor?.format(.quote) }.keyboardShortcut("'", modifiers: [.command, .option])
            }
            .disabled(editor?.canFormat != true)
            Divider()
            Group {
                Button(editor?.hasTitle == true ? "Remove Title" : "Add Title") { editor?.toggleTitle() }
                    .keyboardShortcut("t", modifiers: [.command, .control])
                Button("Insert Image…") { editor?.chooseImage() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            .disabled(editor?.canEdit != true)
        }
        CommandGroup(after: .sidebar) {
            Button(editor?.isPreviewing == true ? "Hide Preview" : "Show Preview") { editor?.togglePreview() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(editor?.canShowPreview != true)
            Button("Reload") { navigation.reloadRequest += 1 }
                .keyboardShortcut("r")
                .disabled(!lock.isUnlocked || !navigation.canReload)
            Button(window.isFocused ? "Exit Focus Mode" : "Enter Focus Mode") { window.toggleFocus() }
                // Not ⌘\, which 1Password takes system-wide.
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!canWrite)
            Divider()
            Button("Zoom In") { zoom(by: 1) }
                .keyboardShortcut("+")
                .disabled(textSize >= MarkdownStyler.textSizes.upperBound)
            Button("Zoom Out") { zoom(by: -1) }
                .keyboardShortcut("-")
                .disabled(textSize <= MarkdownStyler.textSizes.lowerBound)
            Button("Actual Size") { textSize = MarkdownStyler.defaultTextSize }
                .keyboardShortcut("0")
                .disabled(textSize == MarkdownStyler.defaultTextSize)
            Divider()
            Button("Search") { window.searchRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!canWrite || window.isFocused)
            Divider()
        }
        CommandMenu("Go") {
            // Site names stay out of the menu bar while Quill is locked.
            if lock.isUnlocked {
                ForEach(Array(window.siteList.prefix(7).enumerated()), id: \.element.id) { index, site in
                    Button(site.name) { go(to: .site(site.id)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                        .disabled(!canWrite)
                }
            }
            Divider()
            Button("Drafts") { go(to: .drafts) }
                .keyboardShortcut("8", modifiers: [.command, .option])
                .disabled(!canWrite)
            Button("Outbox") { go(to: .outbox) }
                .keyboardShortcut("9", modifiers: [.command, .option])
                .disabled(!canWrite)
        }
        CommandGroup(after: .appSettings) {
            Button("Lock Quill") { lock.lock() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!lock.isUnlocked)
        }
        CommandGroup(replacing: .help) {
            Button("Markdown Guide") { openURL(URL(string: "https://www.markdownguide.org/basic-syntax/")!) }
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
            Divider()
            Button("Release Notes") { openURL(URL(string: "https://github.com/stephenmhoc/quill/releases")!) }
            Button("Quill Website") { openURL(URL(string: "https://github.com/stephenmhoc/quill")!) }
        }
    }

    private func zoom(by step: Double) {
        textSize = min(max(textSize + step, MarkdownStyler.textSizes.lowerBound), MarkdownStyler.textSizes.upperBound)
    }

    /// A sidebar row, and out of Focus Mode to see it.
    private func go(to item: SidebarItem) {
        window.exitFocus()
        if navigation.columnVisibility == .detailOnly { navigation.columnVisibility = .all }
        navigation.sidebar = item
    }
}

/// Help > Keyboard Shortcuts: everything the menus don't already say.
private struct ShortcutsView: View {
    private let groups: [(String, [(String, String)])] = [
        ("Writing", [
            ("New Entry", "⌘N"), ("Publish, Save or Edit", "⌘↩"), ("Save on a local site", "⌘S"),
            ("Add or Remove Title", "⌃⌘T"), ("Tags", "⌥⌘T"), ("Insert Image", "⇧⌘I"),
            ("Continue a list", "Return"), ("Indent or outdent a list item", "Tab, ⇧Tab"),
            ("Move between title and text", "↑ ↓, Tab, ⇧Tab"),
        ]),
        ("Formatting", [
            ("Bold", "⌘B"), ("Italic", "⌘I"), ("Link", "⌘K"), ("Heading 1 to 6", "⌘1 to ⌘6"),
            ("List", "⌥⌘L"), ("Quote", "⌥⌘'"),
        ]),
        ("View", [
            ("Show or Hide Sidebar", "⌃⌘S"), ("Show Preview", "⌥⌘P"), ("Focus Mode", "⇧⌘F"),
            ("Leave Focus Mode", "Esc"), ("Zoom In, Zoom Out, Actual Size", "⌘+, ⌘−, ⌘0"),
            ("Search", "⌥⌘F"), ("Reload", "⌘R"),
        ]),
        ("Go", [("Sites", "⌥⌘1 to ⌥⌘7"), ("Drafts", "⌥⌘8"), ("Outbox", "⌥⌘9")]),
        ("Quill", [("Lock Quill", "⇧⌘L"), ("Export as Markdown", "⇧⌘E"), ("Open Markdown", "⌘O")]),
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.0) { item in
                        LabeledContent(item.0) { Text(item.1).monospaced().foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 560)
    }
}
