import AppIntents

/// Shortcuts and Siri: open Quill on a blank page, with some words already on it if given.
struct NewEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "New Entry"
    static let description = IntentDescription("Opens a blank page in Quill, with the text on it if you give some.")
    static let openAppWhenRun = true

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String?

    @MainActor func perform() async throws -> some IntentResult {
        AppRequests.shared.newEntry = .init(text: text)
        return .result()
    }
}

struct QuillShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewEntryIntent(),
                    phrases: ["New entry in \(.applicationName)", "Write in \(.applicationName)"],
                    shortTitle: "New Entry", systemImageName: "square.and.pencil")
    }
}
