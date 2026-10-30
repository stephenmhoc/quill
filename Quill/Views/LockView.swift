import SwiftUI

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
                Label("Unlock with \(lock.biometryName)", systemImage: "faceid")
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
        .task(id: scenePhase) {
            if scenePhase == .background { didAutoPrompt = false }
            if scenePhase == .active, !didAutoPrompt {
                didAutoPrompt = true
                await lock.unlock()
            }
        }
    }
}
