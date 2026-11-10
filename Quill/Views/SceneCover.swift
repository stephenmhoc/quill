import SwiftUI
import UIKit

/// The windows that cover one scene: the lock, and the app switcher's privacy cover. They sit above
/// the scene's own window, so everything under them stays alive, open sheets included, and
/// unlocking comes back to exactly where the writing was.
@Observable
final class SceneCover {
    /// The scene's own window, found by `SceneWindowReader`.
    @ObservationIgnored weak var window: UIWindow?
    /// Passed to the lock, which only prompts while its scene is in front.
    var phase: ScenePhase = .active
    @ObservationIgnored private var lockWindow: UIWindow?
    @ObservationIgnored private var privacyWindow: UIWindow?

    func setLocked(_ locked: Bool, lock: AppLock) {
        guard locked else {
            lockWindow?.isHidden = true
            lockWindow = nil
            window?.makeKey()
            return
        }
        guard lockWindow == nil, let scene = window?.windowScene else { return }
        let cover = makeWindow(in: scene, level: .alert, root: LockHost(cover: self).environment(lock))
        // Key, so a hardware keyboard can't type into the page underneath.
        cover.makeKeyAndVisible()
        lockWindow = cover
        // After this update, so the editor can note that it had the keyboard.
        DispatchQueue.main.async { [weak self] in self?.window?.endEditing(true) }
    }

    /// Covers everything in the app switcher snapshot.
    func setPrivate(_ visible: Bool) {
        guard visible else {
            privacyWindow?.isHidden = true
            privacyWindow = nil
            return
        }
        guard privacyWindow == nil, let scene = window?.windowScene else { return }
        let cover = makeWindow(in: scene, level: .alert + 1, root: PrivacyCover())
        cover.isHidden = false
        privacyWindow = cover
    }

    private func makeWindow(in scene: UIWindowScene, level: UIWindow.Level, root: some View) -> UIWindow {
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = level
        // A separate window doesn't see `preferredColorScheme`, so it follows Settings itself.
        cover.overrideUserInterfaceStyle = Appearance.current.interfaceStyle
        let host = UIHostingController(rootView: root)
        host.view.accessibilityViewIsModal = true
        cover.rootViewController = host
        return cover
    }
}

private struct LockHost: View {
    /// Weak: the cover holds the window this is in.
    weak var cover: SceneCover?

    var body: some View {
        LockView().environment(\.scenePhase, cover?.phase ?? .active)
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("Quill").font(.system(.title2, design: .monospaced).weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}

/// Finds the window a view is in.
struct SceneWindowReader: UIViewRepresentable {
    let found: (UIWindow) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) { view.found = found }

    final class ReaderView: UIView {
        var found: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { found?(window) }
        }
    }
}

extension Appearance {
    static var current: Appearance {
        UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .auto
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .auto: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}
