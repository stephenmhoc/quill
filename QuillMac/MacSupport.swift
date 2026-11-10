import AppKit
import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The Mac window's own state, beside the `Navigation` it shares with iOS.
@Observable
final class MacWindowState {
    /// Nothing can be written until there's a site, so the menus wait for one.
    var hasSites = false
    /// Measured, so the editor knows how much room the preview really has.
    var sidebarWidth: CGFloat = 260
    var listWidth: CGFloat = 380
    /// The sidebar's search field, narrowing whichever list is showing. View > Search goes to it.
    var searchText = ""
    var searchRequest = 0
    var showingImporter = false
    /// The sites by name, for the Go menu, which can't query the store itself.
    var siteList: [(id: UUID, name: String)] = []
    /// Something in the Outbox has failed, so Retry All has work to do.
    var hasFailures = false
    /// Site > Edit Site… and Remove Site…, from the menu bar or the sidebar.
    var editingSite: Site?
    var removingSite: Site?
    /// Focus Mode: the page alone, over the window. Its own state, so nothing in the columns
    /// (their visibility, folds or widths) changes for it.
    private(set) var isFocused = false
    /// The page Focus Mode shows: the open editor's own text view.
    let focusStage = FocusStage()
    /// Focus Mode: the traffic lights and the sidebar toggle come back while the pointer moves,
    /// and go once writing starts.
    private(set) var focusChromeShown = false
    private var chromeTask: Task<Void, Never>?
    private var lastPointer: NSPoint?

    func toggleFocus() { if isFocused { exitFocus() } else { enterFocus() } }

    func enterFocus() {
        guard !isFocused else { return }
        lastPointer = nil
        chromeTask?.cancel()
        focusChromeShown = false
        isFocused = true
    }

    func exitFocus() {
        guard isFocused else { return }
        chromeTask?.cancel()
        focusChromeShown = false
        isFocused = false
    }

    /// The window's sidebar toggle, View > Hide Sidebar and ⌃⌘S. In Focus Mode they leave it,
    /// since there's no sidebar to show over the page.
    func toggleSidebar(_ navigation: Navigation) {
        if isFocused { return exitFocus() }
        withAnimation { navigation.columnVisibility = navigation.columnVisibility == .all ? .doubleColumn : .all }
    }

    /// Only a pointer that really moved: layout shifting under a still one reports moves too.
    /// Over the title bar the buttons stay, so they don't vanish from under the pointer.
    func pointerMoved(to pointer: NSPoint, inTitleBar: Bool) {
        guard isFocused else { return }
        defer { lastPointer = pointer }
        if let last = lastPointer, hypot(pointer.x - last.x, pointer.y - last.y) <= 3 { return }
        focusChromeShown = true
        chromeTask?.cancel()
        guard !inTitleBar else { return }
        chromeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.focusChromeShown = false }
        }
    }

    func hideFocusChrome() {
        chromeTask?.cancel()
        if focusChromeShown { focusChromeShown = false }
    }

    /// A word in the status bar after something finishes, like a publish.
    private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    func announce(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.notice = nil }
        }
    }
}

/// The open editor's page, which Focus Mode borrows. Set by the editor once it's on screen.
@Observable final class FocusStage {
    @ObservationIgnored weak var page: MacPageHost? {
        didSet { if page !== oldValue { generation += 1 } }
    }
    /// Bumped for each new page, so Focus Mode moves on to it (⌘N while focused).
    private(set) var generation = 0
}

/// Undo for things that aren't text, through the window's undo manager.
enum UndoAction {
    static func register(_ manager: UndoManager?, name: String, _ action: @escaping @MainActor () -> Void) {
        guard let manager else { return }
        // The manager holds its target unowned, so the target must outlive the step: the manager itself.
        manager.registerUndo(withTarget: manager) { _ in MainActor.assumeIsolated { action() } }
        manager.setActionName(name)
    }
}

/// Unsent entries, deleted so Undo puts them back and Redo deletes them again. Nothing else
/// keeps a copy of a draft.
enum EntryDeletion {
    static func delete(_ entries: [Entry], in context: ModelContext, navigation: Navigation, undoManager: UndoManager?,
                       onRestore: @escaping @MainActor ([Entry]) -> Void = { _ in }) {
        let doomed = entries.filter { $0.modelContext != nil && !$0.isDeleted && $0.state != .sending }
        guard !doomed.isEmpty else { return }
        let snapshots = doomed.map(Entry.Snapshot.init)
        // Every window lets go of them, not only this one.
        for entry in doomed { navigation.forget(entry) }
        for entry in doomed { context.delete(entry) }
        try? context.save()
        let name = doomed.count == 1 ? "Delete Entry" : "Delete Entries"
        UndoAction.register(undoManager, name: name) {
            let restored = snapshots.map { $0.restore(in: context) }
            try? context.save()
            onRestore(restored)
            UndoAction.register(undoManager, name: name) {
                delete(restored, in: context, navigation: navigation, undoManager: undoManager, onRestore: onRestore)
            }
        }
    }
}

/// Plain-text copies made for drags in and out live in one folder, emptied at launch and quit.
enum TransferFolder {
    nonisolated static let url = FileManager.default.temporaryDirectory.appending(path: "Quill Transfers")

    /// A new, empty folder inside it.
    nonisolated static func make() throws -> URL {
        let folder = url.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

extension UTType {
    /// The system's Markdown type. Declared in Info.plist too, for Macs that don't know it.
    nonisolated static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// An entry as a `.md` file: dragged out of a list, saved with Export, or opened as a draft.
nonisolated struct MarkdownFile: Transferable {
    let name: String
    let text: String

    @MainActor init(entry: Entry) {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        text = title.isEmpty ? entry.body : "# \(title)\n\n\(entry.body)"
        let base = entry.isBlank ? "Untitled" : entry.displayTitle
        name = String(base.map { "/:\\".contains($0) ? "-" : $0 }.prefix(80)) + ".md"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .markdownText) { file in
            let url = try TransferFolder.make().appending(path: file.name)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
        ProxyRepresentation(exporting: \.text)
    }

    /// File > Export as Markdown. One entry asks where to save it, several ask for a folder.
    @MainActor static func export(_ entries: [Entry]) {
        let files = entries.map(MarkdownFile.init)
        guard !files.isEmpty else { return }
        if files.count == 1, let file = files.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.name
            panel.allowedContentTypes = [.markdownText]
            panel.canCreateDirectories = true
            run(panel) { url in try file.text.write(to: url, atomically: true, encoding: .utf8) }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose a folder for \(files.count) Markdown files."
            run(panel) { folder in
                var used: Set<String> = []
                for file in files {
                    var name = file.name
                    var n = 2
                    while used.contains(name) || FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
                        name = "\(file.name.dropLast(3)) \(n).md"
                        n += 1
                    }
                    used.insert(name)
                    try file.text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    @MainActor private static func run(_ panel: NSSavePanel, write: @escaping (URL) throws -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try write(url) } catch { NSAlert(error: error).runModal() }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Opened or dropped files become drafts. A first line that's a heading becomes the title.
    @MainActor @discardableResult
    static func makeDrafts(from urls: [URL], in context: ModelContext, siteID: UUID?) -> [Entry] {
        var made: [Entry] = []
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let entry = Entry(siteID: siteID)
            // Any line ending: Windows files end lines with "\r\n", and old Mac files with "\r".
            var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            if let first = lines.first, first.hasPrefix("# ") {
                entry.title = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
                lines.removeFirst()
                while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            }
            entry.body = lines.joined(separator: "\n")
            guard !entry.isBlank else { continue }
            context.insert(entry)
            made.append(entry)
        }
        try? context.save()
        return made
    }

    static let openableTypes: [UTType] = [.markdownText, .plainText]
}

/// The Dock shows how many entries need you, and a failed send says so while Quill is behind
/// other apps. Neither carries any writing or names.
enum Attention {
    /// Nil until the first look, so what had already failed before launch isn't announced again.
    private static var knownFailures: Set<UUID>?

    static func update(_ context: ModelContext) {
        let failed = Entry.State.failed.rawValue
        let ids = Set(((try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.stateRaw == failed }))) ?? []).map(\.id))
        NSApp.dockTile.badgeLabel = ids.isEmpty ? nil : "\(ids.count)"
        let new = knownFailures.map { ids.subtracting($0) } ?? []
        knownFailures = ids
        if !new.isEmpty, !NSApp.isActive { notify(count: new.count) }
    }

    private static func notify(count: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = count == 1 ? "An entry couldn't be sent" : "\(count) entries couldn't be sent"
            content.body = "They're waiting in the Outbox."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

extension SiteColor {
    /// A coloured dot for a menu, which would otherwise draw every icon in one colour.
    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            // Drawn when shown, so it follows light and dark.
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
