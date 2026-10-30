import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Site.createdAt) private var sites: [Site]
    @AppStorage(AppLock.graceKey) private var grace: Double = 30
    @AppStorage(Navigation.defaultSiteKey) private var defaultSite = ""
    @AppStorage(Appearance.key) private var appearance = Appearance.auto

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("Writing") {
                    Picker("Default site", selection: $defaultSite) {
                        Text("Last used").tag("")
                        ForEach(sites) { Text($0.name).tag($0.id.uuidString) }
                    }
                }
                Section {
                    Picker("Require \(lock.biometryName)", selection: $grace) {
                        Text("Immediately").tag(0.0)
                        Text("After 30 seconds").tag(30.0)
                        Text("After 1 minute").tag(60.0)
                        Text("After 5 minutes").tag(300.0)
                    }
                    Button("Lock Now") { dismiss(); lock.lock() }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Writing stays on this device and is excluded from backups.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
