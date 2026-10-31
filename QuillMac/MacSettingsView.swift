import SwiftData
import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            SecurityPane().tabItem { Label("Security", systemImage: "lock") }
        }
        .frame(width: 460)
    }
}

private struct GeneralPane: View {
    @Query(sort: \Site.createdAt) private var sites: [Site]
    @AppStorage(Appearance.key) private var appearance = Appearance.auto
    @AppStorage(Navigation.defaultSiteKey) private var defaultSite = ""

    var body: some View {
        Form {
            Picker("Appearance:", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("New entries go to:", selection: $defaultSite) {
                Text("Last used").tag("")
                ForEach(sites) { Text($0.name).tag($0.id.uuidString) }
            }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { Updates.checksAutomatically }, set: { Updates.checksAutomatically = $0 }
            ))
        }
        .padding(20)
    }
}

private struct SecurityPane: View {
    @Environment(AppLock.self) private var lock
    @AppStorage(AppLock.graceKey) private var grace = AppLock.defaultGrace

    var body: some View {
        Form {
            Picker("Require \(lock.biometryName):", selection: $grace) {
                Text("Immediately").tag(0.0)
                Text("After 1 minute").tag(60.0)
                Text("After 5 minutes").tag(300.0)
                Text("After 15 minutes").tag(900.0)
                Text("After 1 hour").tag(3600.0)
            }
            Text("After you leave Quill. It always locks when your Mac sleeps or its screen locks. Writing stays on this Mac and is excluded from backups.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Lock Now") { lock.lock() }
                .disabled(!lock.isUnlocked)
        }
        .padding(20)
    }
}
