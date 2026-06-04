import Foundation

/// Resolves the on-disk directory the Rust core uses for its database, so the
/// app can offer a "reset local data" affordance when core construction fails
/// (audit L31). This mirrors `core/src/storage.rs::default_data_dir()` exactly:
/// the app passes an empty `dataDir` to `CoreConfig`, which makes the core fall
/// back to its platform default, so the Swift side has to reproduce the same
/// derivation to know which directory to move aside.
///
/// Derivation (macOS): prefer a non-empty `XDG_DATA_HOME`, else
/// `~/Library/Application Support`, then append `lyrebird-desktop`. Pulled into
/// a pure function of an environment map so it stays unit-testable.
enum CoreDataLocation {
    /// The directory the core stores its data in for the current process.
    static var defaultDataDirectory: URL? {
        resolve(environment: ProcessInfo.processInfo.environment,
                home: NSHomeDirectory())
    }

    /// Pure resolver used by `defaultDataDirectory` and the tests. Returns `nil`
    /// only when neither `XDG_DATA_HOME` nor a home directory is available
    /// (matching the core's `dirs_next_like()` returning `None`).
    static func resolve(environment: [String: String], home: String?) -> URL? {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
        }
        guard let home, !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// The app's data subfolder name, matching the core's `default_data_dir`.
    static let folderName = "lyrebird-desktop"

    /// Move the core's data directory aside to a timestamped sibling so the next
    /// launch starts from a clean slate without destroying the user's old data
    /// outright (it can still be recovered from the renamed folder). Returns the
    /// backup location on success. A no-op (returns `nil`) when the directory
    /// doesn't exist yet.
    @discardableResult
    static func quarantineDataDirectory(
        _ directory: URL? = CoreDataLocation.defaultDataDirectory,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL? {
        guard let directory, fileManager.fileExists(atPath: directory.path) else { return nil }
        let stamp = backupStamp(now)
        let backup = directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent).corrupt-\(stamp)", isDirectory: true)
        try fileManager.moveItem(at: directory, to: backup)
        return backup
    }

    /// Filename-safe timestamp for the quarantine folder suffix.
    static func backupStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }
}
