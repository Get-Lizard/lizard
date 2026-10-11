import AppKit
import ExtensionHost
import Foundation
import LizardCore
import Observation
import Search

/// Everything Lizard can carry to another Mac: settings, shortcuts, quicklinks, the extension
/// list (with their preferences and stored data), optionally notes, work log and chats.
/// API keys never leave the Keychain; clipboard history stays on this Mac.
struct PortableSnapshot: Codable {
    struct ExtensionEntry: Codable, Hashable {
        var name: String
        var source: ExtensionSource
        var menuBarCommands: [String]
    }

    var format = 1
    var created = Date()
    var device = Host.current().localizedName ?? "Mac"
    var settings: [String: Data] = [:]
    var quicklinks: [Quicklink] = []
    var quicklinksModified: Date?
    var extensions: [ExtensionEntry] = []
}

enum Portability {
    /// Keys that belong to this Mac (folders, setup progress, system changes Lizard made here).
    private static let deviceOnly: Set<String> = [
        "Lizard.SetupCompleted", "Lizard.SetupStep", "Lizard.NotesFolder", "Lizard.WorkLogFolder", "Lizard.iCloudSync",
        "Lizard.DeviceID", "Lizard.SpotlightShortcutDisabled", "Lizard.StatusItemOrderV3",
    ]

    /// UserDefaults keys that travel: Lizard settings and the recorded shortcuts. Applied with the
    /// same rule, so a backup or another Mac can't write anything else (folders, system keys…).
    static func isPortable(_ key: String) -> Bool {
        (key.hasPrefix("Lizard.") || key.hasPrefix("KeyboardShortcuts_")) && !deviceOnly.contains(key)
    }

    static func portableSettings() -> [String: Data] {
        var result: [String: Data] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where isPortable(key) {
            if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) { result[key] = data }
        }
        return result
    }

    static func applySettings(_ settings: [String: Data]) {
        for (key, data) in settings where isPortable(key) {
            if let value = try? PropertyListSerialization.propertyList(from: data, format: nil) { UserDefaults.standard.set(value, forKey: key) }
        }
    }

    @MainActor
    static func snapshot(app: AppModel) async -> PortableSnapshot {
        var snapshot = PortableSnapshot()
        snapshot.settings = portableSettings()
        snapshot.quicklinks = await app.quicklinks.links
        snapshot.quicklinksModified = (try? AppPaths.applicationSupport.appending(path: "quicklinks.json").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        snapshot.extensions = app.extensions.installed.map { item in
            PortableSnapshot.ExtensionEntry(
                name: item.name, source: item.source,
                menuBarCommands: item.commands.filter { app.extensions.isMenuBarEnabled(item.name, $0.name) }.map(\.name))
        }
        return snapshot
    }
}

// MARK: - Backup file

/// `.lizardbackup` (a zip): snapshot.json + extension data + packages that can't be re-downloaded
/// + optionally notes, work log and chats.
@MainActor
enum BackupService {
    struct Options {
        var notes = true
        var chats = false
    }

    static func export(app: AppModel, options: Options, to file: URL) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "lizard-backup-\(UUID().uuidString)/Lizard Backup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

        let snapshot = await Portability.snapshot(app: app)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: staging.appending(path: "snapshot.json"))

        for item in app.extensions.installed {
            let target = staging.appending(path: "extensions/\(item.name)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            // Data: preferences (passwords excluded) and the extension's own storage.
            let passwords = Set(item.manifest.allPreferences(for: nil).filter { $0.type == "password" }.map(\.name)
                + item.commands.flatMap { ($0.preferences ?? []).filter { $0.type == "password" }.map(\.name) })
            let preferences = await app.extensions.store.savedPreferences(item.name).filter { !passwords.contains($0.key) }
            try JSONEncoder().encode(preferences).write(to: target.appending(path: "preferences.json"))
            if FileManager.default.fileExists(atPath: item.supportDirectory.path) {
                try FileManager.default.copyItem(at: item.supportDirectory, to: target.appending(path: "support"))
            }
            // Code that can't be fetched again from GitHub travels with the backup.
            if item.source.github == nil {
                _ = try await ProcessRunner.run("/usr/bin/rsync", ["-a", "--exclude", "node_modules", item.packageDirectory.path + "/", target.appending(path: "package").path + "/"])
            }
        }
        if options.notes {
            for (folder, name) in [(Preferences.notesFolder, "notes"), (Preferences.workLogFolder, "worklogs")] where FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.copyItem(at: folder, to: staging.appending(path: name))
            }
        }
        if options.chats {
            try? FileManager.default.copyItem(at: ChatStore.directory, to: staging.appending(path: "chats"))
        }
        try? FileManager.default.removeItem(at: file)
        let zip = try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", staging.path, file.path], timeout: .seconds(600))
        guard zip.succeeded else { throw ExtensionHostError.buildFailed(zip.tail(4)) }
    }

    /// Restores a backup. Existing notes are kept; files from the backup are added next to them.
    static func restore(app: AppModel, from file: URL, progress: @escaping (String) -> Void) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "lizard-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unzip = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", file.path, staging.path], timeout: .seconds(600))
        let root = staging.appending(path: "Lizard Backup", directoryHint: .isDirectory)
        guard unzip.succeeded, let data = try? Data(contentsOf: root.appending(path: "snapshot.json")) else {
            throw ExtensionHostError.download("this isn't a Lizard backup")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(PortableSnapshot.self, from: data)

        progress("Restoring settings and shortcuts…")
        Portability.applySettings(snapshot.settings)
        await app.quicklinks.replaceAll(snapshot.quicklinks)

        for entry in snapshot.extensions {
            // Names come from the backup file: never let one point outside its folder.
            guard ExtensionStore.isSafeName(entry.name) else {
                progress("Skipped an extension with an invalid name")
                continue
            }
            progress("Installing \(entry.name)…")
            let saved = root.appending(path: "extensions/\(entry.name)", directoryHint: .isDirectory)
            do {
                if let location = entry.source.github {
                    try await app.extensions.store.install(location)
                } else if FileManager.default.fileExists(atPath: saved.appending(path: "package/package.json").path) {
                    try await app.extensions.store.install(saved.appending(path: "package").path, builtIn: !entry.source.isExternal)
                }
                if let installed = await app.extensions.store.extensionNamed(entry.name) {
                    if let prefs = try? JSONDecoder().decode([String: HostJSON].self, from: Data(contentsOf: saved.appending(path: "preferences.json"))) {
                        try? await app.extensions.store.setPreferences(entry.name, values: prefs.mapValues { Optional($0) })
                    }
                    let support = saved.appending(path: "support")
                    if FileManager.default.fileExists(atPath: support.path) {
                        _ = try? await ProcessRunner.run("/usr/bin/rsync", ["-a", support.path + "/", installed.supportDirectory.path + "/"])
                    }
                }
            } catch {
                progress("Skipped \(entry.name): \(error.localizedDescription)")
            }
        }
        for (name, folder) in [("notes", Preferences.notesFolder), ("worklogs", Preferences.workLogFolder)] {
            let saved = root.appending(path: name)
            if FileManager.default.fileExists(atPath: saved.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = try? await ProcessRunner.run("/usr/bin/rsync", ["-a", "--ignore-existing", saved.path + "/", folder.path + "/"])
            }
        }
        let chats = root.appending(path: "chats")
        if FileManager.default.fileExists(atPath: chats.path) {
            _ = try? await ProcessRunner.run("/usr/bin/rsync", ["-a", "--ignore-existing", chats.path + "/", ChatStore.directory.path + "/"])
        }
        await app.extensions.reload()
        for entry in snapshot.extensions {
            for command in entry.menuBarCommands { app.extensions.setMenuBar(entry.name, command, enabled: true) }
        }
        app.quicklinksChanged()
        progress("Restored from \(snapshot.device), \(snapshot.created.formatted(date: .abbreviated, time: .shortened)).")
    }
}

// MARK: - iCloud sync

/// Sync through iCloud Drive (your Apple ID; no account or server of ours):
/// - Notes and work log can live in `iCloud Drive/Lizard/…`, which macOS syncs file by file.
/// - Each Mac writes `iCloud Drive/Lizard/Sync/<Mac>.json` (its snapshot); every Mac reads the
///   others' and takes the newest quicklinks and settings, and offers extensions it doesn't have.
@Observable
@MainActor
final class SyncService {
    static let enabledKey = "Lizard.iCloudSync"

    private(set) var lastSync: Date?
    private(set) var status: String?
    /// Extensions installed on another Mac but not here (installed only after the user agrees).
    private(set) var offeredExtensions: [PortableSnapshot.ExtensionEntry] = []

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { start() }
        }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "Lizard.DeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "Lizard.DeviceID")
        return id
    }()

    init(app: AppModel) {
        self.app = app
    }

    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    static var isICloudDriveAvailable: Bool { FileManager.default.fileExists(atPath: iCloudDrive.path) }
    static var root: URL { iCloudDrive.appending(path: "Lizard", directoryHint: .isDirectory) }
    private var syncFolder: URL { Self.root.appending(path: "Sync", directoryHint: .isDirectory) }

    var notesInICloud: Bool { Preferences.notesFolder.path.hasPrefix(Self.iCloudDrive.path) }

    func start() {
        guard isEnabled, Self.isICloudDriveAvailable, loop == nil else { return }
        loop = Task {
            while !Task.isCancelled, isEnabled {
                await pull()
                try? await Task.sleep(for: .seconds(120))
            }
            loop = nil
        }
        scheduleWrite()
    }

    /// Something portable changed here: write this Mac's snapshot shortly.
    func scheduleWrite() {
        guard isEnabled else { return }
        pendingWrite?.cancel()
        pendingWrite = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let app else { return }
            await write(Portability.snapshot(app: app))
        }
    }

    private func write(_ snapshot: PortableSnapshot) async {
        do {
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: syncFolder.appending(path: "\(deviceID).json"), options: .atomic)
            lastSync = .now
            status = nil
        } catch {
            status = "Couldn't write to iCloud Drive: \(error.localizedDescription)"
        }
    }

    /// Reads the other Macs' snapshots and applies what's newer.
    func pull() async {
        guard let app, let files = try? FileManager.default.contentsOfDirectory(at: syncFolder, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var others: [PortableSnapshot] = []
        for file in files where file.lastPathComponent != "\(deviceID).json" {
            if file.pathExtension == "icloud" {
                // Evicted by "Optimize Mac Storage": ask iCloud to bring it back for next time.
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                continue
            }
            if file.pathExtension == "json", let data = try? Data(contentsOf: file), let snapshot = try? decoder.decode(PortableSnapshot.self, from: data) {
                others.append(snapshot)
            }
        }
        let mine = await Portability.snapshot(app: app)
        // Quicklinks: the most recently edited list wins.
        if let newest = others.filter({ $0.quicklinksModified != nil }).max(by: { $0.quicklinksModified! < $1.quicklinksModified! }),
            let theirs = newest.quicklinksModified, theirs > (mine.quicklinksModified ?? .distantPast).addingTimeInterval(1),
            newest.quicklinks != mine.quicklinks {
            await app.quicklinks.replaceAll(newest.quicklinks)
            app.quicklinksChanged()
        }
        // Settings: from the most recent snapshot newer than this Mac's last write.
        if let newest = others.max(by: { $0.created < $1.created }), newest.created > (lastSync ?? .distantPast) {
            Portability.applySettings(newest.settings)
        }
        let installed = Set(app.extensions.installed.map(\.name))
        var offers: [String: PortableSnapshot.ExtensionEntry] = [:]
        for snapshot in others {
            for entry in snapshot.extensions where !installed.contains(entry.name) && (entry.source.github != nil || !entry.source.isExternal) {
                offers[entry.name] = entry
            }
        }
        offeredExtensions = offers.values.sorted { $0.name < $1.name }
        lastSync = .now
    }

    func installOffered(_ entry: PortableSnapshot.ExtensionEntry) {
        guard let app, let location = entry.source.github else { return }
        Task {
            _ = try? await app.extensions.store.install(location)
            await app.extensions.reload()
            for command in entry.menuBarCommands { app.extensions.setMenuBar(entry.name, command, enabled: true) }
            offeredExtensions.removeAll { $0.name == entry.name }
            scheduleWrite()
        }
    }

    /// Moves notes and work log into iCloud Drive (or back), keeping every file.
    func moveNotes(toICloud: Bool) async throws {
        let targets = toICloud
            ? (Self.root.appending(path: "Notes", directoryHint: .isDirectory), Self.root.appending(path: "WorkLogs", directoryHint: .isDirectory))
            : (Preferences.documents.appending(path: "Notes", directoryHint: .isDirectory), Preferences.documents.appending(path: "WorkLogs", directoryHint: .isDirectory))
        for (from, to) in [(Preferences.notesFolder, targets.0), (Preferences.workLogFolder, targets.1)] where from != to {
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: from.path) {
                let copy = try await ProcessRunner.run("/usr/bin/rsync", ["-a", "--ignore-existing", from.path + "/", to.path + "/"], timeout: .seconds(600))
                guard copy.succeeded else { throw ExtensionHostError.buildFailed(copy.tail(3)) }
            }
        }
        Preferences.notesFolder = targets.0
        Preferences.workLogFolder = targets.1
        app?.reloadNotesFolders()
    }
}
