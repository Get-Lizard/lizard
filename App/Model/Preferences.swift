import Foundation

/// App-wide preferences that aren't AI settings (those live in `ProviderSettings`).
enum Preferences {
    private static let notesKey = "Lizard.NotesFolder"
    private static let workLogKey = "Lizard.WorkLogFolder"
    static let clipboardEnabledKey = "Lizard.ClipboardEnabled"
    static let githubOfferedKey = "Lizard.GitHubExtensionOffered"

    static var documents: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents", directoryHint: .isDirectory) }

    static var notesFolder: URL {
        get { UserDefaults.standard.url(forKey: notesKey) ?? documents.appending(path: "Notes", directoryHint: .isDirectory) }
        set { UserDefaults.standard.set(newValue, forKey: notesKey) }
    }

    static var workLogFolder: URL {
        get { UserDefaults.standard.url(forKey: workLogKey) ?? documents.appending(path: "WorkLogs", directoryHint: .isDirectory) }
        set { UserDefaults.standard.set(newValue, forKey: workLogKey) }
    }

    /// Reopen the launcher on the screen it was left on (default) instead of a fresh search.
    static var resumeLauncher: Bool {
        get { UserDefaults.standard.object(forKey: "Lizard.ResumeLauncher") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "Lizard.ResumeLauncher") }
    }

    static var clipboardEnabled: Bool {
        get { UserDefaults.standard.object(forKey: clipboardEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: clipboardEnabledKey) }
    }
}
