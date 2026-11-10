import SwiftData
import SwiftUI

@main
struct QuillApp: App {
    static let windowID = "main"

    @UIApplicationDelegateAdaptor private var delegate: QuillAppDelegate
    private let container: ModelContainer
    @State private var lock: AppLock
    @State private var publisher: Publisher
    @AppStorage(Appearance.key) private var appearance = Appearance.auto

    init() {
        Telemetry.start()
        #if DEBUG
        if CommandLine.arguments.contains("-disableAnimations") { UIView.setAnimationsEnabled(false) }
        #endif
        Appearance.alignLargeTitles()
        let container = QuillStore.makeContainer()
        let lock = AppLock()
        let publisher = Publisher(lock: lock, context: container.mainContext)
        self.container = container
        _lock = State(initialValue: lock)
        _publisher = State(initialValue: publisher)
        // The app's, not a window's: two windows would send and fetch twice.
        Task { await publisher.runWhileUnlocked() }
    }

    var body: some Scene {
        WindowGroup(id: Self.windowID) {
            SceneRoot()
                .environment(lock)
                .environment(publisher)
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(container)
        .commands { QuillCommands(lock: lock, context: container.mainContext) }
    }
}

/// One window. Each has its own navigation, so two iPad windows can show different pages.
private struct SceneRoot: View {
    @State private var navigation = Navigation()

    var body: some View {
        RootView()
            .environment(navigation)
    }
}

/// Requests from outside a window, like a Home Screen quick action or a shortcut, waiting for a
/// window that can take them: unlocked, in front, and with a site to write on.
@Observable
final class AppRequests {
    static let shared = AppRequests()

    struct NewEntry: Equatable {
        let id = UUID()
        var text: String?
        /// The window a quick action opened, or nil for whichever is in front.
        var sceneID: String?
    }

    var newEntry: NewEntry?
}

/// Only here to hand each window the scene delegate below.
final class QuillAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = QuillSceneDelegate.self
        return configuration
    }
}

/// Home Screen quick actions, listed in `project.yml`.
final class QuillSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// A quick action that launched Quill. Here rather than when the scene is configured, which
    /// is skipped for a window restored from last time.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { QuickAction.perform(item, in: session) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickAction.perform(shortcutItem, in: windowScene.session))
    }
}

enum QuickAction {
    static let newEntry = "com.merimerimeri.Quill.newEntry"

    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem, in session: UISceneSession) -> Bool {
        guard item.type == newEntry else { return false }
        AppRequests.shared.newEntry = .init(sceneID: session.persistentIdentifier)
        return true
    }
}
