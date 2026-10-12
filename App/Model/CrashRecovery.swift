import AppKit
import Foundation
import LizardCore

/// Keeps Lizard running: a tiny watcher process relaunches it if it ever exits without quitting
/// properly (a crash, a force-quit by the system). Quitting from the menu, Homebrew upgrades and
/// in-app updates mark a clean exit, so they aren't undone. Three crashes within two minutes stop
/// the retries, so a broken build can't loop.
@MainActor
enum CrashRecovery {
    private static var directory: URL { AppPaths.ensure(AppPaths.applicationSupport.appending(path: "Recovery", directoryHint: .isDirectory)) }
    private static var cleanMarker: URL { directory.appending(path: "clean-exit-\(ProcessInfo.processInfo.processIdentifier)") }
    private static var restarts: URL { directory.appending(path: "restarts.log") }
    private static var sigterm: DispatchSourceSignal?

    /// True when this launch is a recovery from a crash (show a gentle note).
    static var recovered: Bool { CommandLine.arguments.contains("--recovered") }

    static func start() {
        // A development build launched with flags (tests, captures) isn't guarded.
        let flags = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") && $0 != "--recovered" }
        guard flags.isEmpty else { return }
        handleTerminateSignal()
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundleURL.path
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 1; done
            if [ -f "\(cleanMarker.path)" ]; then rm -f "\(cleanMarker.path)"; exit 0; fi
            now=$(date +%s)
            recent=$(awk -v now="$now" '$1 > now - 120' "\(restarts.path)" 2>/dev/null | wc -l | tr -d ' ')
            [ "${recent:-0}" -ge 3 ] && exit 0
            echo "$now" >> "\(restarts.path)"
            sleep 1
            /usr/bin/open -n "\(app)" --args --recovered
            """
        _ = try? ProcessRunner.launch("/bin/sh", ["-c", script], onLine: { _ in })
    }

    /// Normal quits (menu, updates, Homebrew's "quit app").
    static func markCleanExit() {
        FileManager.default.createFile(atPath: cleanMarker.path, contents: Data())
    }

    /// `kill` (SIGTERM) from scripts or the system counts as a deliberate stop.
    private static func handleTerminateSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                markCleanExit()
                exit(0)
            }
        }
        source.resume()
        sigterm = source
    }
}
