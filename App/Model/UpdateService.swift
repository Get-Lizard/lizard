import AppKit
import Foundation
import LizardCore
import Observation

/// Checks GitHub Releases for a newer Lizard and installs it in one click: `brew upgrade` when
/// Homebrew installed it, otherwise download the DMG, check it's signed by the same developer and
/// notarized, swap the app in place and relaunch.
@Observable
@MainActor
final class UpdateService {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Quitting to restart into a new version: skip the graceful shutdown. The app's files were
    /// just replaced, and touching the AI engine on the way out (to wait for it) can hang.
    @ObservationIgnored private(set) var isRelaunching = false
    private(set) var lastChecked: Date?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?

    static let autoCheckKey = "Lizard.CheckForUpdates"
    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }
    private static let announcedKey = "Lizard.UpdateAnnounced"
    /// Signed by this team or not installed at all.
    private static let teamID = "6H728M7XQK"

    init(app: AppModel) {
        self.app = app
    }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var available: AppRelease? {
        if case .available(let release) = state { release } else { nil }
    }

    /// Daily background check, the first a minute after launch.
    func start() {
        guard loop == nil else { return }
        loop = Task {
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                if Self.autoCheck { await check(announce: true) }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check(announce: Bool = false) async {
        if case .installing = state { return }
        state = .checking
        do {
            var request = URLRequest(url: AppRelease.latestAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let release = AppRelease.parse(data) else {
                state = .failed("Couldn't read the latest release from GitHub.")
                return
            }
            lastChecked = .now
            guard AppRelease.isNewer(release.version, than: currentVersion) else {
                state = .upToDate
                return
            }
            state = .available(release)
            // One heads-up per version; it stays in the menu and Settings after that.
            if announce, UserDefaults.standard.string(forKey: Self.announcedKey) != release.version {
                UserDefaults.standard.set(release.version, forKey: Self.announcedKey)
                app?.showHUD("Lizard \(release.version) is available. Install it from the menu bar or Settings")
            }
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    // MARK: Install

    /// The cask's install, if Homebrew put Lizard here.
    private var homebrewCask: (brew: String, caskroom: URL)? {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let caskroom = URL(filePath: "\(prefix)/Caskroom/lizard")
            if FileManager.default.fileExists(atPath: caskroom.path), FileManager.default.isExecutableFile(atPath: "\(prefix)/bin/brew") {
                return ("\(prefix)/bin/brew", caskroom)
            }
        }
        return nil
    }

    /// Updating in place only makes sense for an installed app (not a development build).
    private var isInstalledApp: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func install() {
        guard let release = available else { return }
        guard isInstalledApp else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        Task {
            if let cask = homebrewCask {
                await installWithHomebrew(cask.brew, release: release)
            } else if let dmg = release.dmgURL {
                await installFromDMG(dmg, release: release)
            } else {
                NSWorkspace.shared.open(release.pageURL)
            }
        }
    }

    /// Homebrew quits Lizard while upgrading it (the cask's `uninstall quit`), so the upgrade runs
    /// in a small script after Lizard has quit: pull the tap, upgrade, reinstall if the app on disk
    /// is still old (stale Homebrew records), then reopen. Lizard checks its version on the next
    /// launch and falls back to the verified DMG if Homebrew still didn't deliver.
    private func installWithHomebrew(_ brew: String, release: AppRelease) async {
        state = .installing("Updating with Homebrew…")
        let tap = URL(filePath: brew).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Library/Taps/get-lizard/homebrew-tap").path
        let app = Bundle.main.bundleURL.path
        let log = AppPaths.applicationSupport.appending(path: "update.log").path
        let script = """
            exec >"\(log)" 2>&1
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
            export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
            git -C "\(tap)" pull --ff-only --quiet
            "\(brew)" upgrade --cask get-lizard/tap/lizard
            installed=$(defaults read "\(app)/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
            if [ "$installed" != "\(release.version)" ]; then "\(brew)" reinstall --cask get-lizard/tap/lizard; fi
            /usr/bin/open "\(app)"
            """
        UserDefaults.standard.set(release.version, forKey: Self.expectedKey)
        _ = try? ProcessRunner.launch("/bin/sh", ["-c", script], onLine: { _ in })
        quitForUpdate()
    }

    private static let expectedKey = "Lizard.UpdateExpected"

    /// After an update restart: if this isn't the version we updated to, finish it from the DMG.
    func verifyAfterUpdate() {
        guard let expected = UserDefaults.standard.string(forKey: Self.expectedKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.expectedKey)
        guard AppRelease.isNewer(expected, than: currentVersion) else {
            app?.showHUD("Updated to Lizard \(currentVersion)")
            return
        }
        Task {
            await check()
            guard let release = available, let dmg = release.dmgURL, isInstalledApp else {
                state = .failed("The update to \(expected) didn't install. Run `brew lizard-update` in Terminal or download it from GitHub.")
                return
            }
            await installFromDMG(dmg, release: release)
        }
    }

    private func installFromDMG(_ url: URL, release: AppRelease) async {
        let work = FileManager.default.temporaryDirectory.appending(path: "lizard-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        let mount = work.appending(path: "mount", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            state = .installing("Downloading Lizard \(release.version)…")
            let (downloaded, _) = try await URLSession.shared.download(from: url)
            let dmg = work.appending(path: "Lizard.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)

            state = .installing("Checking the download…")
            let attach = try await ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path], timeout: .seconds(120))
            guard attach.succeeded else { throw UpdateError("Couldn't open the downloaded disk image.") }
            defer { Task.detached { _ = try? await ProcessRunner.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], timeout: .seconds(60)) } }
            let newApp = mount.appending(path: "Lizard.app")
            let staged = work.appending(path: "Lizard.app")
            let copy = try await ProcessRunner.run("/usr/bin/ditto", [newApp.path, staged.path], timeout: .seconds(300))
            guard copy.succeeded else { throw UpdateError("Couldn't copy the new version.") }
            try await verify(staged)

            state = .installing("Installing…")
            UserDefaults.standard.set(release.version, forKey: Self.expectedKey)
            let current = Bundle.main.bundleURL
            let backup = work.appending(path: "Lizard-old.app")
            try FileManager.default.moveItem(at: current, to: backup)
            do {
                try FileManager.default.moveItem(at: staged, to: current)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: current)  // put the old one back
                throw UpdateError("Couldn't replace the app (\(error.localizedDescription)).")
            }
            relaunch()
        } catch let error as UpdateError {
            state = .failed(error.message)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    /// Same developer as the running app, sealed, and accepted by Gatekeeper (notarized).
    private func verify(_ app: URL) async throws {
        let seal = try await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: .seconds(120))
        guard seal.succeeded else { throw UpdateError("The new version's signature doesn't check out, so it wasn't installed.") }
        let info = try await ProcessRunner.run("/usr/bin/codesign", ["-dv", app.path], timeout: .seconds(30))
        guard info.output.contains("TeamIdentifier=\(Self.teamID)") else { throw UpdateError("The new version isn't signed by Lizard's developer, so it wasn't installed.") }
        let gatekeeper = try await ProcessRunner.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: .seconds(120))
        guard gatekeeper.succeeded else { throw UpdateError("macOS didn't accept the new version (not notarized), so it wasn't installed.") }
    }

    /// Quit cleanly so the update script can replace the app (no relaunch from here).
    private func quitForUpdate() {
        state = .installing("Restarting…")
        isRelaunching = true
        NSApp.terminate(nil)
    }

    /// Quit and start the new version once this process has exited.
    private func relaunch() {
        state = .installing("Restarting…")
        isRelaunching = true
        let path = Bundle.main.bundleURL.path
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(path)\""
        _ = try? ProcessRunner.launch("/bin/sh", ["-c", script], onLine: { _ in })
        NSApp.terminate(nil)
    }

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
