import ExtensionHost
import Foundation
import Observation

/// One running view command: the latest tree from the extension plus local UI state (search
/// text, selection, form values, toast).
@Observable
@MainActor
final class ExtensionSession: Identifiable {
    struct ToastState: Equatable {
        var id: Int
        var style: String
        var title: String
        var message: String?
        var actionTitle: String?
        var actionCallback: String?
    }

    let id = UUID()
    let installed: InstalledExtension
    let command: ExtensionManifest.Command
    private(set) var tree: [ViewNode] = []
    private(set) var depth = 0
    private(set) var toast: ToastState?
    private(set) var failure: String?
    private(set) var finished = false
    var searchText = ""
    var selectedID: Int?
    /// Uncontrolled form field values by field id.
    var formValues: [String: HostJSON] = [:]

    @ObservationIgnored let runtime: ExtensionRuntime
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored var onNotify: ((String, HostJSON) -> Void)?
    @ObservationIgnored private var toastTimer: Task<Void, Never>?

    init(installed: InstalledExtension, command: ExtensionManifest.Command, runtime: ExtensionRuntime) {
        self.installed = installed
        self.command = command
        self.runtime = runtime
    }

    var root: ViewNode? { tree.first }

    func listen() {
        listenTask = Task { [weak self, runtime] in
            for await event in runtime.events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: HostEvent) {
        switch event {
        case .render(let tree, let depth):
            if depth != self.depth {
                searchText = ""
                selectedID = nil
                formValues = [:]
            }
            self.tree = tree
            self.depth = depth
        case .notify(let method, let params):
            switch method {
            case "toast.show":
                showToast(params)
            case "toast.hide":
                if toast?.id == Int(params["id"]?.number ?? -1) { toast = nil }
            default:
                onNotify?(method, params)
            }
        case .done:
            finished = true
        case .error(let message, let stack):
            failure = stack.isEmpty ? message : "\(message)\n\n\(stack.prefix(1500))"
        case .exited:
            finished = true
        }
    }

    private func showToast(_ params: HostJSON) {
        let state = ToastState(
            id: Int(params["id"]?.number ?? 0), style: params["style"]?.string ?? "SUCCESS", title: params["title"]?.string ?? "",
            message: params["message"]?.string, actionTitle: params["primaryAction"]?["title"]?.string,
            actionCallback: params["primaryAction"]?["callback"]?.string)
        toast = state
        toastTimer?.cancel()
        guard state.style != "ANIMATED" else { return }
        toastTimer = Task {
            try? await Task.sleep(for: .seconds(state.style == "FAILURE" ? 6 : 3))
            if !Task.isCancelled, toast?.id == state.id { toast = nil }
        }
    }

    func invoke(_ callback: String?, _ args: [HostJSON] = []) {
        guard let callback else { return }
        runtime.invoke(callback, args: args)
    }

    /// Esc inside the extension: pop its navigation; false when already at its root.
    func pop() -> Bool {
        guard depth > 0 else { return false }
        runtime.pop()
        return true
    }

    func stop() {
        listenTask?.cancel()
        runtime.stop()
    }
}
