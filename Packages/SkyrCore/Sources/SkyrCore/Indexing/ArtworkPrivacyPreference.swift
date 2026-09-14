import Foundation

/// Consent is not part of a profile, shared defaults, iCloud, or a device backup.
struct ArtworkPrivacyPreference {
    let fileURL: URL

    init(fileURL: URL = AppDirectories.support.appending(path: "Skyr/ArtworkPrivacy/apple-artwork-v1")) {
        self.fileURL = fileURL
    }

    func load() -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]),
              values.isExcludedFromBackup == true else { return false }
        return (try? Data(contentsOf: fileURL)) == Data("enabled-v1".utf8)
    }

    var enabledAt: Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func save(_ enabled: Bool) throws {
        guard enabled else {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            return
        }
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try Data("enabled-v1".utf8).write(to: fileURL, options: .atomic)
        var file = fileURL
        do { try file.setResourceValues(values) }
        catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }
}
