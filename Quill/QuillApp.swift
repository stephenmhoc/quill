import SwiftData
import SwiftUI

@main
struct QuillApp: App {
    private let container: ModelContainer
    @State private var lock = AppLock()
    @State private var navigation = Navigation()
    @State private var publisher: Publisher

    init() {
        let container = Self.makeContainer()
        let lock = AppLock()
        self.container = container
        _lock = State(initialValue: lock)
        _publisher = State(initialValue: Publisher(lock: lock, context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(lock)
                .environment(navigation)
                .environment(publisher)
        }
        .modelContainer(container)
        .commands { QuillCommands(navigation: navigation) }
    }

    /// Local-only store in Application Support, excluded from iCloud/iTunes backup.
    private static func makeContainer() -> ModelContainer {
        let fm = FileManager.default
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Quill")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try dir.setResourceValues(values)
        } catch {
            fatalError("Couldn't exclude the Quill store from backups: \(error)")
        }
        let config = ModelConfiguration(url: dir.appending(path: "Quill.store"), cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: Site.self, Entry.self, configurations: config)
        } catch {
            fatalError("Couldn't open the Quill store: \(error)")
        }
    }
}

/// Menu-bar / ⌘-key shortcuts on iPad with a keyboard.
struct QuillCommands: Commands {
    let navigation: Navigation

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Entry") {
                NotificationCenter.default.post(name: .quillNewEntry, object: nil)
            }
            .keyboardShortcut("n")
        }
        CommandGroup(after: .sidebar) {
            Button("Focus Mode") { navigation.toggleFocus() }
                .keyboardShortcut("\\")
        }
    }
}

extension Notification.Name {
    static let quillNewEntry = Notification.Name("quillNewEntry")
}
