import Sparkle

/// Updates for the DMG build, from the feed in `Info.plist`.
enum Updates {
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: isReleaseBuild, updaterDelegate: nil, userDriverDelegate: nil
    )

    /// A development build isn't signed like the releases, so it can't install one.
    private static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    static var canCheck: Bool { isReleaseBuild }
    static func check() { controller.checkForUpdates(nil) }

    static var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
