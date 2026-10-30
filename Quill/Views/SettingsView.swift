import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Site.createdAt) private var sites: [Site]
    @AppStorage(AppLock.graceKey) private var grace: Double = 30
    @AppStorage(Navigation.defaultSiteKey) private var defaultSite = ""
    @AppStorage(Appearance.key) private var appearance = Appearance.auto
    @State private var icon = AppIconChoice.current
    @State private var iconError: String?

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
                Section {
                    HStack(spacing: 20) {
                        ForEach(AppIconChoice.allCases) { option in
                            Button { choose(option) } label: { IconOption(option: option, isSelected: option == icon) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(option.label) icon")
                                .accessibilityAddTraits(option == icon ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity)
                } header: {
                    Text("Icon")
                } footer: {
                    if let iconError { Text(iconError).foregroundStyle(.red) }
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

    private func choose(_ option: AppIconChoice) {
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(option.iconName)
                icon = option
                iconError = nil
            } catch {
                iconError = error.localizedDescription
            }
        }
    }
}

private struct IconOption: View {
    let option: AppIconChoice
    let isSelected: Bool

    private let size: CGFloat = 68
    private var shape: some Shape { RoundedRectangle(cornerRadius: 15, style: .continuous) }

    var body: some View {
        VStack(spacing: 8) {
            preview
                .frame(width: size, height: size)
                .clipShape(shape)
                .overlay { shape.stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2.5 : 1) }
            Text(option.label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }

    @ViewBuilder private var preview: some View {
        switch option {
        case .paper: Image("IconPaper").resizable()
        case .ink: Image("IconInk").resizable()
        case .auto:
            // Half and half: this one follows the system's light or dark mode.
            Image("IconPaper").resizable().overlay(alignment: .trailing) {
                Image("IconInk").resizable()
                    .mask(alignment: .trailing) { Rectangle().frame(width: size / 2) }
            }
        }
    }
}
