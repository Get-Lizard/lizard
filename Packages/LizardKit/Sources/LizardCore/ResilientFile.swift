import Foundation

/// Saves that survive crashes and corruption: every write is atomic and keeps the previous
/// good copy as `<file>.bak`; reading falls back to the backup when the main file is missing
/// or can't be decoded (a crash mid-write, a disk hiccup, a bad edit) and restores it.
public enum ResilientFile {
    static func backupURL(_ url: URL) -> URL { url.appendingPathExtension("bak") }

    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = backupURL(url)
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Decodes the file, or its backup (restoring it) when the file is damaged.
    public static func read<T>(_ url: URL, decode: (Data) throws -> T) -> T? {
        if let data = try? Data(contentsOf: url), let value = try? decode(data) { return value }
        let backup = backupURL(url)
        guard let data = try? Data(contentsOf: backup), let value = try? decode(data) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            // Keep the damaged copy for diagnosis, then put the good one back.
            try? FileManager.default.removeItem(at: url.appendingPathExtension("damaged"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("damaged"))
        }
        try? data.write(to: url, options: .atomic)
        return value
    }
}
