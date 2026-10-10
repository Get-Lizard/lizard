import CryptoKit
import Foundation
import Network

/// "Sign in with OpenRouter": OAuth PKCE in the browser, no API key to copy. A one-shot HTTP
/// listener on a random localhost port receives the callback; the code is exchanged for a key
/// the user controls (and can revoke) on openrouter.ai.
public enum OpenRouterAuth {
    public enum AuthError: Error, LocalizedError {
        case cancelled, timedOut, denied, exchangeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: "Sign-in was cancelled."
            case .timedOut: "Sign-in took too long. Please try again."
            case .denied: "OpenRouter didn't return a sign-in code. Please try again."
            case .exchangeFailed(let detail): "Couldn't finish signing in: \(detail)"
            }
        }
    }

    /// What the waiting screen needs while the browser step is open.
    public struct Pending: Sendable {
        /// The sign-in page (to open it again).
        public let page: URL
        /// The same sign-in without a redirect: OpenRouter shows a code to paste into Lizard —
        /// works even when the browser won't hand off to localhost.
        public let codePage: URL
        /// PKCE verifier for exchanging a pasted code.
        public let verifier: String
    }

    /// Runs the whole flow and returns the API key. `openBrowser` opens the sign-in page;
    /// `pending` hands the waiting screen what it needs for "open again" and "use a code".
    public static func signIn(openBrowser: @escaping @MainActor (URL) -> Void, pending: (@MainActor (Pending) -> Void)? = nil) async throws -> String {
        let verifier = randomVerifier()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let catcher = try CallbackCatcher()
        let port = try await catcher.start()
        defer { catcher.cancel() }

        func authURL(callback: String?) -> URL {
            var components = URLComponents(string: "https://openrouter.ai/auth")!
            components.queryItems = (callback.map { [URLQueryItem(name: "callback_url", value: $0)] } ?? []) + [
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "key_label", value: "Lizard"),
            ]
            return components.url!
        }
        let page = authURL(callback: "http://localhost:\(port)/callback")
        await pending?(Pending(page: page, codePage: authURL(callback: nil), verifier: verifier))
        await openBrowser(page)

        let code = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await catcher.code() }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    throw AuthError.timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } onCancel: {
            catcher.cancel()
        }
        return try await exchange(code: code, verifier: verifier)
    }

    /// Trades a code (from the redirect or pasted from OpenRouter's code page) for the API key.
    public static func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let key = json["key"] as? String, !key.isEmpty
        else {
            throw AuthError.exchangeFailed(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return key
    }

    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    /// Parses `GET /callback?code=… HTTP/1.1` → code.
    static func code(fromRequest request: String) -> String?? {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[1].hasPrefix("/callback") else { return nil }  // e.g. /favicon.ico
        let components = URLComponents(string: "http://localhost" + parts[1])
        return .some(components?.queryItems?.first { $0.name == "code" }?.value)
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot loopback HTTP listener for the OAuth redirect. Only accepts local connections.
private final class CallbackCatcher: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.lizard.openrouter-auth")
    private var waiter: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    /// Only touched on `queue` (the listener's callback queue).
    private var started = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self, listener] state in
                guard let self, !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    self.started = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func code() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result {
                    continuation.resume(with: result)
                } else {
                    self.waiter = continuation
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(OpenRouterAuth.AuthError.cancelled)) }
    }

    private func finish(_ outcome: Result<String, Error>) {
        guard result == nil else { return }
        result = outcome
        listener.cancel()
        waiter?.resume(with: outcome)
        waiter = nil
    }

    private func handle(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            guard let parsed = OpenRouterAuth.code(fromRequest: request) else {
                Self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            let ok = parsed != nil
            Self.respond(connection, status: "200 OK", body: Self.page(success: ok))
            self.finish(parsed.map { .success($0) } ?? .failure(OpenRouterAuth.AuthError.denied))
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || "\(address)".hasSuffix("127.0.0.1")
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(success: Bool) -> String {
        let title = success ? "You're connected ✨" : "Sign-in didn't finish"
        let text = success ? "You can close this tab and go back to Lizard." : "Go back to Lizard and try again."
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>Lizard</title>
            <style>body{font:16px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#0f0f14;color:#fff}
            div{text-align:center}h1{font-size:28px;margin:0 0 8px}p{opacity:.7}</style></head>
            <body><div><h1>\(title)</h1><p>\(text)</p></div><script>setTimeout(()=>window.close(),1500)</script></body></html>
            """
    }
}
