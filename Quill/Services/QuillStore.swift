import Foundation
import SwiftData

enum QuillStore {
    /// Local-only store in Application Support, excluded from iCloud/iTunes backup.
    static func makeContainer() -> ModelContainer {
        let fm = FileManager.default
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Quill")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try dir.setResourceValues(values)
        } catch {
            fatalError("Couldn't exclude the Quill store from backups: \(error)")
        }
        let config = ModelConfiguration(url: dir.appending(path: "Quill.store"), cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: Site.self, Entry.self, configurations: config)
        } catch {
            fatalError("Couldn't open the Quill store: \(error)")
        }
    }
}
