import SwiftUI
#if os(macOS)
import AppKit
#endif

struct LockView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    /// One automatic prompt per return to the app, so cancelling doesn't re-prompt forever.
    @State private var didAutoPrompt = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Quill")
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
            if let error = lock.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Button {
                Task { await lock.unlock() }
            } label: {
                Label("Unlock with \(lock.biometryName)", systemImage: lock.biometryIcon)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(lock.isAuthenticating)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        #if os(macOS)
        // A Mac's scene stays active behind other apps, and Quill can lock back there. The prompt
        // takes over the screen, so it waits until Quill is in front.
        .task { if NSApp.isActive { await autoPrompt() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await autoPrompt() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            didAutoPrompt = false
        }
        #else
        .task(id: scenePhase) {
            if scenePhase == .background { didAutoPrompt = false }
            if scenePhase == .active { await autoPrompt() }
        }
        #endif
    }

    private func autoPrompt() async {
        guard !didAutoPrompt else { return }
        didAutoPrompt = true
        await lock.unlock()
    }
}
