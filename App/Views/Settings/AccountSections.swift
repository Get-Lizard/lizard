import AIEngine
import LizardCore
import SwiftUI

/// AI choices shared by Setup and Settings: Apple Intelligence, a local MLX model, opt-in clouds.
struct AISetupSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var ai = app.ai
        VStack(alignment: .leading, spacing: 12) {
            AppleIntelligenceRow()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "cpu").foregroundStyle(Brand.moss).frame(width: 24)
                    Text("Local model").font(.headline)
                    Spacer()
                    Picker("", selection: $ai.settings.mlxModelID) {
                        ForEach(ModelCatalog.all) { model in
                            Text("\(model.name) · \(String(format: "%.1f", model.downloadGB)) GB").tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                if let model = ai.localModel {
                    let fit = ModelCatalog.fit(model, budgetBytes: HardwareProfile.current.gpuBudgetBytes)
                    Text("\(model.blurb) \(fit.label).").font(.callout).foregroundStyle(.secondary)
                }
                if AppleIntelligence.status == .unsupported, !ai.isLocalModelDownloaded {
                    Label("Recommended for this Mac: free and private, like Apple Intelligence. Download it once.", systemImage: "star.fill")
                        .font(.callout).foregroundStyle(Brand.moss)
                }
                downloadRow
            }
            .padding(12)
            .surface()

            Toggle(isOn: $ai.settings.cloudEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow cloud AI").font(.headline)
                    Text("Use OpenRouter, OpenCode Zen, Claude or OpenAI when you sign in to them. Off keeps everything on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(12)
            .surface()

            if ai.settings.cloudEnabled {
                CloudSignInSection()
            }
        }
    }

    @ViewBuilder
    private var downloadRow: some View {
        let ai = app.ai
        if ai.isLocalModelDownloaded {
            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.moss).font(.callout)
        } else {
            switch ai.download {
            case .running(let fraction, let text):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction).tint(Brand.moss)
                    HStack {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { ai.cancelDownload() }.buttonStyle(.link).font(.caption)
                    }
                }
            case .loading:
                ProgressView("Loading into memory…").controlSize(.small)
            case .failed(let message):
                HStack {
                    Text(message).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { ai.downloadLocalModel() }
                }
            case .idle, .done:
                Button("Download") { ai.downloadLocalModel() }
                    .buttonStyle(.borderedProminent).tint(Brand.moss)
            }
        }
    }
}

/// Apple Intelligence with what to do when it's off: open the right System Settings pane, wait for
/// the download, or point at the local model. Re-checks every few seconds while visible, so fixing
/// it in System Settings shows up here without restarting.
struct AppleIntelligenceRow: View {
    @State private var status = AppleIntelligence.status

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.intelligence").foregroundStyle(Brand.moss).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.moss)
            case .turnedOff:
                Button("Turn On…") { NSWorkspace.shared.open(Self.settingsPane) }
                    .buttonStyle(.borderedProminent).tint(Brand.moss)
            case .downloading:
                ProgressView().controlSize(.small)
            case .unsupported:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .surface()
        .task {
            while !Task.isCancelled, status != .ready {
                try? await Task.sleep(for: .seconds(3))
                let latest = AppleIntelligence.status
                if latest != status { withAnimation(.smooth) { status = latest } }
            }
        }
    }

    private var detail: String {
        switch status {
        case .ready: "Ready. Free, private and instant: Apple's model runs on this Mac, nothing to download."
        case .turnedOff: "Free and built into macOS, but switched off. Turn it on in System Settings › Apple Intelligence & Siri; Lizard notices right away."
        case .downloading: "Switched on. macOS is downloading Apple's model; Lizard starts using it as soon as it's ready."
        case .unsupported: "Not available on this Mac (it needs Apple Intelligence support for your Mac, region and language). Use the free local model below instead."
        }
    }

    static let settingsPane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
}

/// Browser sign-ins for cloud AI (Cocoon's flows): OpenRouter OAuth and OpenCode Zen.
struct CloudSignInSection: View {
    @Environment(AppModel.self) private var app
    @State private var pastedKey = ""

    var body: some View {
        let accounts = app.accounts
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Brand.teal).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenRouter").font(.headline)
                    Text(openRouterText(accounts.openRouter)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                switch accounts.openRouter {
                case .signedIn: Button("Sign out") { accounts.signOutOfOpenRouter() }
                case .waiting(let page): Button("Open again") { NSWorkspace.shared.open(page) }
                default: Button("Sign in with browser") { accounts.signInToOpenRouter() }.buttonStyle(.borderedProminent).tint(Brand.teal)
                }
            }
            .padding(12)
            .surface()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(Brand.teal).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenCode Zen").font(.headline)
                        Text(accounts.openCodeKeySource ?? "Sign in on opencode.ai. If you use the OpenCode CLI, Lizard picks up its login automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if accounts.openCodeKeySource == nil {
                        Button("Sign in") { accounts.openOpenCodeSignIn() }.buttonStyle(.borderedProminent).tint(Brand.teal)
                    } else {
                        Button("Forget") { accounts.saveOpenCodeKey("") }
                    }
                }
                if accounts.openCodeKeySource == nil {
                    HStack {
                        SecureField("Paste your Zen key", text: $pastedKey).textFieldStyle(.roundedBorder)
                        Button("Save") { accounts.saveOpenCodeKey(pastedKey); pastedKey = "" }.disabled(pastedKey.isEmpty)
                        Button("Check again") { accounts.refreshOpenCode() }
                    }
                    .padding(.leading, 36)
                }
            }
            .padding(12)
            .surface()
        }
    }

    private func openRouterText(_ state: AccountsModel.OpenRouterState) -> String {
        switch state {
        case .signedIn: "Signed in. Claude, GPT, Gemini and free models through one account."
        case .waiting: "Finish signing in in your browser…"
        case .failed(let message): message
        case .signedOut: "One browser sign-in for Claude, GPT, Gemini and free models."
        }
    }
}

/// GitHub through the `gh` CLI with a device-code browser sign-in, plus the menu-bar extension.
struct GitHubConnectSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let accounts = app.accounts
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark").font(.title2).foregroundStyle(Brand.moss).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub account").font(.headline)
                    Text(statusText(accounts.github)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch accounts.github {
                case .signedIn:
                    Button("Sign out") { accounts.signOutOfGitHub() }
                case .working, .checking:
                    ProgressView().controlSize(.small)
                case .enterCode:
                    Button("Cancel") { accounts.cancelGitHub() }
                default:
                    Button("Sign in with browser") { accounts.signInToGitHub() }
                        .buttonStyle(.borderedProminent).tint(Brand.moss)
                }
            }
            if case .enterCode(let code, let url) = accounts.github {
                HStack(spacing: 14) {
                    Text(code).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enter this code on GitHub (it's on your clipboard).").font(.callout)
                        Button("Open github.com/login/device") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.moss.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .surface()
        .onAppear { if accounts.github == .unknown { accounts.refreshGitHub() } }

        GitHubExtensionRow()
    }

    private func statusText(_ state: AccountsModel.GitHubState) -> String {
        switch state {
        case .unknown, .checking: "Checking for GitHub CLI…"
        case .signedOut: "Uses GitHub's official CLI. Lizard installs it if needed, then you approve in your browser."
        case .working(let text): text
        case .enterCode: "Waiting for you to approve in the browser…"
        case .signedIn(let user, _, let managed): "Signed in as @\(user)" + (managed ? " (Lizard's GitHub CLI)" : " (your GitHub CLI)")
        case .failed(let message): message
        }
    }
}

/// Installs the GitHub Review Requests extension and turns on its menu-bar command.
struct GitHubExtensionRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let state = app.extensions.githubDefaultState
        HStack(spacing: 12) {
            Image(systemName: "menubar.rectangle").font(.title2).foregroundStyle(Brand.teal).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub Review Requests").font(.headline)
                Text(state.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .installing: ProgressView().controlSize(.small)
            case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.moss)
            default:
                Button("Add to menu bar") { app.extensions.installGitHubDefault(accounts: app.accounts) }
                    .disabled(app.accounts.githubStatus == nil)
            }
        }
        .padding(12)
        .surface()
    }
}
