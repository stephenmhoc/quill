import AppKit
import SwiftData
import SwiftUI

@main
struct QuillMacApp: App {
    private let container: ModelContainer
    @State private var lock: AppLock
    @State private var navigation = Navigation()
    @State private var publisher: Publisher
    @AppStorage(Appearance.key) private var appearance = Appearance.auto

    init() {
        let container = QuillStore.makeContainer()
        let lock = AppLock()
        #if DEBUG
        if CommandLine.arguments.contains("-skipUnlock") { lock.unlockForTesting(keys: [:]) }
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
                .frame(minWidth: 760, minHeight: 480)
                .onChange(of: appearance, initial: true) { _, choice in
                    NSApp.appearance = choice.colorScheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) } ?? nil
                }
        }
        .modelContainer(container)
        .defaultSize(width: 1240, height: 800)
        .commands { MacCommands(navigation: navigation, lock: lock, context: container.mainContext) }

        Settings {
            MacSettingsView()
                .environment(lock)
                .modelContainer(container)
        }
    }
}

/// What the menu bar can do to whichever entry is open.
struct EditorActions {
    let canPublish: Bool
    let canPreview: Bool
    let isPreviewing: Bool
    let publishLabel: String
    let publish: () -> Void
    let format: (MarkdownFormat) -> Void
    let togglePreview: () -> Void
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
        SidebarCommands()
        TextEditingCommands()
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
                Button("Heading") { editor?.format(.heading) }.keyboardShortcut("h", modifiers: [.command, .option])
                Button("List") { editor?.format(.bullet) }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("Quote") { editor?.format(.quote) }.keyboardShortcut("'", modifiers: [.command, .option])
                Divider()
                Button("Add Title") { editor?.toggleTitle() }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Insert Image…") { editor?.chooseImage() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
            .disabled(editor == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(editor?.isPreviewing == true ? "Hide Preview" : "Show Preview") { editor?.togglePreview() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(editor?.canPreview != true)
            Button("Focus Mode") {
                withAnimation { navigation.columnVisibility = navigation.columnVisibility == .detailOnly ? .all : .detailOnly }
            }
            .keyboardShortcut("\\")
            Divider()
        }
        CommandGroup(after: .appSettings) {
            Button("Lock Quill") { lock.lock() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!lock.isUnlocked)
        }
    }
}
