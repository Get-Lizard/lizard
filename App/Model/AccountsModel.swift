import AIEngine
import AppKit
import Foundation
import LizardCore
import Observation

/// Sign-ins, all browser-based (no keys to paste), the way Cocoon does them:
/// GitHub through the official `gh` CLI (device code), OpenRouter through OAuth PKCE, and
/// OpenCode Zen by reusing an existing `opencode auth login` (or a pasted key as a last resort).
@Observable
@MainActor
final class AccountsModel {
    enum GitHubState: Equatable {
        case unknown, checking, signedOut
        case working(String)
        case enterCode(code: String, url: URL)
        case signedIn(user: String, executable: String, managed: Bool)
        case failed(String)
    }

    enum OpenRouterState: Equatable {
        case signedOut
        case waiting(page: URL)
        case signedIn
        case failed(String)
    }

    private(set) var github = GitHubState.unknown
    private(set) var openRouter = OpenRouterState.signedOut
    private(set) var openCodeKeySource: String?

    @ObservationIgnored private var githubTask: Task<Void, Never>?
    @ObservationIgnored private var openRouterTask: Task<Void, Never>?

    init() {
        refreshOpenRouter()
        refreshOpenCode()
    }

    // MARK: GitHub

    var githubStatus: GitHubCLI.Status? {
        if case .signedIn(let user, let executable, let managed) = github {
            return GitHubCLI.Status(executable: executable, username: user, isManaged: managed)
        }
        return nil
    }

    func refreshGitHub() {
        github = .checking
        Task {
            if let status = await GitHubCLI.status(), let user = status.username {
                github = .signedIn(user: user, executable: status.executable, managed: status.isManaged)
            } else {
                github = .signedOut
            }
        }
    }

    func signInToGitHub() {
        githubTask?.cancel()
        github = .working("Starting…")
        githubTask = Task {
            do {
                let status = try await GitHubCLI.signIn { event in
                    Task { @MainActor in
                        switch event {
                        case .status(let text):
                            self.github = .working(text)
                        case .visit(let url, let code):
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            self.github = .enterCode(code: code, url: url)
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                github = .signedIn(user: status.username ?? "", executable: status.executable, managed: status.isManaged)
            } catch is CancellationError {
                github = .signedOut
            } catch {
                github = .failed(error.localizedDescription)
            }
        }
    }

    func cancelGitHub() {
        githubTask?.cancel()
        github = .signedOut
    }

    func signOutOfGitHub() {
        Task {
            await GitHubCLI.signOut()
            refreshGitHub()
        }
    }

    // MARK: OpenRouter (OAuth PKCE)

    func refreshOpenRouter() {
        openRouter = (Keychain.cachedValue(Keychain.openRouterAccount) ?? nil) != nil ? .signedIn : .signedOut
    }

    func signInToOpenRouter() {
        openRouterTask?.cancel()
        openRouterTask = Task {
            do {
                let key = try await OpenRouterAuth.signIn(
                    openBrowser: { NSWorkspace.shared.open($0) },
                    pending: { [weak self] pending in self?.openRouter = .waiting(page: pending.page) })
                Keychain.set(key, for: Keychain.openRouterAccount)
                openRouter = .signedIn
            } catch is CancellationError {
                openRouter = .signedOut
            } catch {
                openRouter = .failed(error.localizedDescription)
            }
        }
    }

    func signOutOfOpenRouter() {
        openRouterTask?.cancel()
        Keychain.set(nil, for: Keychain.openRouterAccount)
        openRouter = .signedOut
    }

    // MARK: OpenCode Zen

    func refreshOpenCode() {
        if (Keychain.cachedValue(Keychain.openCodeAccount) ?? nil) != nil {
            openCodeKeySource = "Saved in Lizard"
        } else if OpenCodeZen.keyFromCLI() != nil {
            openCodeKeySource = "From your OpenCode login"
        } else {
            openCodeKeySource = nil
        }
    }

    /// Zen has no third-party OAuth: open its sign-in page, then pick up the CLI login or a pasted key.
    func openOpenCodeSignIn() {
        NSWorkspace.shared.open(OpenCodeZen.signInPage)
    }

    func saveOpenCodeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed.isEmpty ? nil : trimmed, for: Keychain.openCodeAccount)
        refreshOpenCode()
    }
}
