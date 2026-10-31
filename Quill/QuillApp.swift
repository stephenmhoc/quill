import SwiftData
import SwiftUI

@main
struct QuillApp: App {
    private let container: ModelContainer
    @State private var lock = AppLock()
    @State private var navigation = Navigation()
    @State private var publisher: Publisher
    @AppStorage(Appearance.key) private var appearance = Appearance.auto

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("-disableAnimations") { UIView.setAnimationsEnabled(false) }
        #endif
        Appearance.alignLargeTitles()
        let container = QuillStore.makeContainer()
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
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(container)
        .commands { QuillCommands(navigation: navigation) }
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
