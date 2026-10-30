import Foundation
import GhostKit
import LocalAuthentication
import Observation

/// Face ID gate for the whole app, plus the unlocked session's access to site keys.
@Observable
final class AppLock {
    static let graceKey = "lockGraceSeconds"

    private(set) var isUnlocked = false
    private(set) var isAuthenticating = false
    var lastError: String?

    private var context: LAContext?
    private var backgroundedAt: Date?
    /// Keys read during this unlocked session; cleared on lock.
    private var keyCache: [UUID: String] = [:]

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func unlock() async {
        guard !isUnlocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"
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

    func lock() {
        isUnlocked = false
        context?.invalidate()
        context = nil
        keyCache.removeAll()
    }

    func didEnterBackground() {
        backgroundedAt = .now
    }

    func didBecomeActive() {
        guard isUnlocked, let since = backgroundedAt else { return }
        backgroundedAt = nil
        let grace = UserDefaults.standard.object(forKey: Self.graceKey) as? Double ?? 30
        if Date.now.timeIntervalSince(since) > grace { lock() }
    }

    // MARK: Site keys (only while unlocked)

    func saveKey(_ key: String, for siteID: UUID) throws {
        try TokenStore.save(key, for: siteID, context: context)
        keyCache[siteID] = key
    }

    func deleteKey(for siteID: UUID) {
        TokenStore.delete(siteID)
        keyCache[siteID] = nil
    }

    func client(for site: Site) throws -> GhostClient {
        guard isUnlocked else { throw VaultError.locked }
        guard let url = site.url else { throw GhostError.invalidURL }
        let key: String
        if let cached = keyCache[site.id] {
            key = cached
        } else if let stored = try TokenStore.read(site.id, context: context) {
            keyCache[site.id] = stored
            key = stored
        } else {
            throw VaultError.missingKey(site.name)
        }
        return GhostClient(baseURL: url, credentials: try GhostCredentials(apiKey: key))
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
