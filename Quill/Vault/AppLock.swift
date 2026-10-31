import Foundation
import GhostKit
import LocalAuthentication
import Observation

/// Face ID gate for the whole app, plus the unlocked session's access to site keys.
@Observable
final class AppLock {
    static let graceKey = "lockGraceSeconds"
    #if os(macOS)
    /// Switching apps is part of writing on a Mac, so leaving Quill is a gentler signal.
    static let defaultGrace = 900.0
    #else
    static let defaultGrace = 30.0
    #endif

    private(set) var isUnlocked = false
    private(set) var isAuthenticating = false
    /// False from backgrounding until the app is active again (and re-checked against the grace period).
    private(set) var isForeground = true
    var lastError: String?

    private var context: LAContext?
    private var backgroundedAt: Date?
    private var lockDeadline: Task<Void, Never>?
    /// Keys read during this unlocked session; cleared on lock.
    private var keyCache: [UUID: String] = [:]

    /// New sends only start while unlocked and on screen.
    var canWork: Bool { isUnlocked && isForeground }

    let biometryName: String = {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:
            #if os(macOS)
            return "Password"
            #else
            return "Passcode"
            #endif
        }
    }()

    var biometryIcon: String {
        switch biometryName {
        case "Face ID": "faceid"
        case "Touch ID": "touchid"
        case "Optic ID": "opticid"
        default: "lock"
        }
    }

    func unlock() async {
        guard !isUnlocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let ctx = LAContext()
        #if os(iOS)
        ctx.localizedFallbackTitle = "Use Passcode"
        #endif
        ctx.touchIDAuthenticationAllowableReuseDuration = 10
        do {
            // Biometrics with passcode fallback, so a failed Face ID never locks you out.
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your writing")
            context = ctx
            isUnlocked = true
            lastError = nil
        } catch let error as LAError where error.code == .passcodeNotSet {
            lastError = "Set a device passcode in Settings to use Quill."
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var grace: Double {
        UserDefaults.standard.object(forKey: Self.graceKey) as? Double ?? Self.defaultGrace
    }

    func lock() {
        lockDeadline?.cancel()
        isUnlocked = false
        context?.invalidate()
        context = nil
        keyCache.removeAll()
    }

    func didEnterBackground() {
        backgroundedAt = .now
        isForeground = false
    }

    /// Another app came forward. Quill keeps working behind it, unlike a backgrounded iPhone app,
    /// but its window stays readable, so the grace period has to end without coming back.
    func didResignActive() {
        backgroundedAt = .now
        lockDeadline?.cancel()
        guard grace > 0 else {
            lock()
            return
        }
        lockDeadline = Task { [weak self, grace] in
            try? await Task.sleep(for: .seconds(grace))
            if !Task.isCancelled { self?.lock() }
        }
    }

    func didBecomeActive() {
        isForeground = true
        lockDeadline?.cancel()
        guard isUnlocked, let since = backgroundedAt else { return }
        backgroundedAt = nil
        if Date.now.timeIntervalSince(since) > grace { lock() }
    }

    #if DEBUG
    /// Tests run without Face ID or a Keychain entitlement.
    func unlockForTesting(keys: [UUID: String]) {
        isUnlocked = true
        keyCache = keys
    }
    #endif

    // MARK: Site keys (only while unlocked)

    func saveKey(_ key: String, for siteID: UUID) throws {
        try TokenStore.save(key, for: siteID, context: context)
        keyCache[siteID] = key
    }

    func deleteKey(for siteID: UUID) {
        TokenStore.delete(siteID)
        keyCache[siteID] = nil
    }

    func key(for site: Site) throws -> String {
        guard isUnlocked else { throw VaultError.locked }
        if let cached = keyCache[site.id] { return cached }
        guard let stored = try TokenStore.read(site.id, context: context) else {
            throw VaultError.missingKey(site.name)
        }
        keyCache[site.id] = stored
        return stored
    }

    func client(for site: Site) throws -> GhostClient {
        guard let url = site.url else { throw GhostError.invalidURL }
        return GhostClient(baseURL: url, credentials: try GhostCredentials(apiKey: try key(for: site)))
    }
}

enum VaultError: LocalizedError {
    case locked
    case missingKey(String)

    var errorDescription: String? {
        switch self {
        case .locked: "Quill is locked."
        case .missingKey(let name): "No key saved for \(name). Re-enter it in Sites."
        }
    }
}
