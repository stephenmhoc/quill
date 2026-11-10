import SwiftData
import SwiftUI

/// What the menu bar can do to whichever entry is open in the window in front. The Mac has its own,
/// in `QuillMacApp.swift`.
struct EditorActions {
    let canPublish: Bool
    let publishLabel: String
    let publish: () -> Void
    let canBeginEditing: Bool
    let beginEditing: () -> Void
    let canDiscard: Bool
    let discardChanges: () -> Void
    let viewURL: URL?
    let viewOnSite: () -> Void
    /// Formatting needs a page that can change.
    let canFormat: Bool
    let format: (MarkdownFormat) -> Void
    let hasTitle: Bool
    let toggleTitle: () -> Void
    let canInsertImage: Bool
    let insertImage: () -> Void
    let canPreview: Bool
    let isPreviewing: Bool
    let togglePreview: () -> Void
}

extension FocusedValues {
    @Entry var editorActions: EditorActions?
    /// The window in front's own navigation: each iPad window has one.
    @Entry var sceneNavigation: Navigation?
}

/// The iPad's menu bar, and the shortcuts a keyboard shows when ⌘ is held. Everything is here
/// rather than on buttons, so shortcuts work in focus mode, where the buttons are gone.
struct QuillCommands: Commands {
    let lock: AppLock
    let context: ModelContext
    @FocusedValue(\.sceneNavigation) private var navigation
    @FocusedValue(\.editorActions) private var editor
    @Environment(\.openWindow) private var openWindow

    private var isOpen: Bool { lock.isUnlocked && navigation != nil }
    /// The open entry, while it can be reached.
    private var page: EditorActions? { lock.isUnlocked ? editor : nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Entry") { navigation?.openBlankEntry(in: context) }
                .keyboardShortcut("n")
                .disabled(!isOpen)
            if UIApplication.shared.supportsMultipleScenes {
                Button("New Window") { openWindow(id: QuillApp.windowID) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            Divider()
            Button("Add Site…") { navigation?.showingAddSite = true }
                .disabled(!isOpen)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(page?.publishLabel ?? "Publish") { page?.publish() }
                .keyboardShortcut(.return)
                .disabled(page?.canPublish != true)
            Button("Edit Entry") { page?.beginEditing() }
                .keyboardShortcut("e")
                .disabled(page?.canBeginEditing != true)
            Button("Discard Changes") { page?.discardChanges() }
                .disabled(page?.canDiscard != true)
            Button("View on Site") { page?.viewOnSite() }
                .disabled(page?.viewURL == nil)
        }
        // In place of the system's Font menu, which can't style plain Markdown.
        CommandGroup(replacing: .textFormatting) {
            Group {
                Button("Bold") { page?.format(.bold) }.keyboardShortcut("b")
                Button("Italic") { page?.format(.italic) }.keyboardShortcut("i")
                Button("Link") { page?.format(.link) }.keyboardShortcut("k")
                Divider()
                Button("Heading") { page?.format(.heading) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("List") { page?.format(.bullet) }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("Quote") { page?.format(.quote) }.keyboardShortcut("'", modifiers: [.command, .option])
            }
            .disabled(page?.canFormat != true)
            Divider()
            Button(page?.hasTitle == true ? "Remove Title" : "Add Title") { page?.toggleTitle() }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(page?.canFormat != true)
            Button("Insert Image…") { page?.insertImage() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(page?.canInsertImage != true)
        }
        CommandGroup(after: .sidebar) {
            Button(page?.isPreviewing == true ? "Hide Preview" : "Show Preview") { page?.togglePreview() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(page?.canPreview != true)
            Button("Reload") { navigation?.reloadRequest += 1 }
                .keyboardShortcut("r")
                .disabled(!isOpen || navigation?.canReload != true)
            Button(navigation?.isFocused == true ? "Leave Focus Mode" : "Focus Mode") { navigation?.toggleFocus() }
                // Not ⌘\, which 1Password takes system-wide.
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(page == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { navigation?.showingSettings = true }
                .keyboardShortcut(",")
                .disabled(!isOpen)
            Button("Lock Quill") { lock.lock() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!lock.isUnlocked)
        }
    }
}
