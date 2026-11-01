import AppKit
import SwiftData
import SwiftUI

@main
struct QuillMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    private let container: ModelContainer
    @State private var lock: AppLock
    @State private var navigation = Navigation()
    @State private var publisher: Publisher
    @AppStorage(Appearance.key) private var appearance = Appearance.auto

    init() {
        Updates.start()
        let container = QuillStore.makeContainer()
        let lock = AppLock()
        #if DEBUG
        if CommandLine.arguments.contains("-skipUnlock") { lock.unlockForTesting(keys: [:]) }
        // A site to edit, because saving one for real needs the signed build's Keychain.
        if CommandLine.arguments.contains("-seedGhostSite"), let url = URL(string: "https://key-test.example.com"),
           ((try? container.mainContext.fetch(FetchDescriptor<Site>())) ?? []).allSatisfy({ $0.name != "Key Test" }) {
            container.mainContext.insert(Site(name: "Key Test", url: url, isPublic: false, color: .ocean))
        }
        #endif
        self.container = container
        _lock = State(initialValue: lock)
        _publisher = State(initialValue: Publisher(lock: lock, context: container.mainContext))
    }

    var body: some Scene {
        // One window: a journal is one place, and the outbox and preload should only run once.
        Window("Quill", id: "main") {
            MacRootView()
                .environment(lock)
                .environment(navigation)
                .environment(publisher)
                .frame(minWidth: 920, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { navigation.windowWidth = $0 }
                .onChange(of: appearance, initial: true) { _, choice in
                    NSApp.appearance = choice.colorScheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) } ?? nil
                }
        }
        .modelContainer(container)
        .defaultSize(width: 1320, height: 820)
        .commands { MacCommands(navigation: navigation, lock: lock, context: container.mainContext) }

        Settings {
            MacSettingsView()
                .environment(lock)
                .modelContainer(container)
        }
    }
}

/// The Dock icon's menu.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the window, which knows whether there's anywhere to write yet.
    static var newEntry: (() -> Void)?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Entry", action: #selector(newEntry), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newEntry() {
        NSApp.activate()
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
}

extension FocusedValues {
    @Entry var editorActions: EditorActions?
}

struct MacCommands: Commands {
    let navigation: Navigation
    let lock: AppLock
    let context: ModelContext
    @FocusedValue(\.editorActions) private var editor

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updates.check() }
                .disabled(!Updates.canCheck)
        }
        SidebarCommands()
        TextEditingCommands()
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { NSApp.runPageLayout(nil) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print…") { editor?.print() }
                .keyboardShortcut("p")
                .disabled(editor?.canPreview != true)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Entry") { navigation.openBlankEntry(in: context) }
                .keyboardShortcut("n")
                .disabled(!lock.isUnlocked)
        }
        CommandGroup(after: .newItem) {
            Button("Add Site…") { navigation.showingAddSite = true }
                .disabled(!lock.isUnlocked)
            Divider()
            Button(editor?.publishLabel ?? "Publish") { editor?.publish() }
                .keyboardShortcut(.return)
                .disabled(editor?.canPublish != true)
        }
        CommandMenu("Format") {
            Group {
                Button("Bold") { editor?.format(.bold) }.keyboardShortcut("b")
                Button("Italic") { editor?.format(.italic) }.keyboardShortcut("i")
                Button("Link") { editor?.format(.link) }.keyboardShortcut("k")
                Divider()
                Button("Heading") { editor?.format(.heading) }.keyboardShortcut("1", modifiers: [.command, .option])
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
            Button(navigation.isFocused ? "Leave Focus Mode" : "Focus Mode") { navigation.toggleFocus() }
                // Not ⌘\, which 1Password takes system-wide.
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!lock.isUnlocked)
            Divider()
        }
        CommandGroup(after: .appSettings) {
            Button("Lock Quill") { lock.lock() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!lock.isUnlocked)
        }
    }
}
