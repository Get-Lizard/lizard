import Foundation

/// Minimal Server-Sent Events helpers. Both providers send one complete JSON document per
/// `data:` line, so line-level parsing is enough.
public enum SSE {
    /// Returns the payload of a `data:` line, or nil for comments, `event:` lines and blanks.
    public static func dataPayload(fromLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        return String(payload)
    }

    /// Opens a streaming POST and yields `data:` payloads. Throws on non-2xx with the body.
    /// Transient failures (rate limits, overloaded or unreachable servers, dropped connections)
    /// are retried with backoff — but only before any data arrived, so output is never duplicated.
    static func post(_ request: URLRequest, retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    var receivedData = false
                    do {
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            throw AIProviderError.invalidResponse("not an HTTP response")
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            var body = ""
                            for try await line in bytes.lines {
                                body += line + "\n"
                                if body.count > 4000 { break }
                            }
                            if isTransient(status: http.statusCode), attempt < retryDelays.count {
                                let wait = retryAfter(http) ?? retryDelays[attempt]
                                attempt += 1
                                try await Task.sleep(for: wait)
                                continue
                            }
                            throw AIProviderError.http(status: http.statusCode, body: body)
                        }
                        for try await line in bytes.lines {
                            if let payload = dataPayload(fromLine: line) {
                                receivedData = true
                                continuation.yield(payload)
                            }
                        }
                        continuation.finish()
                        return
                    } catch {
                        if !receivedData, !Task.isCancelled, isTransient(error), attempt < retryDelays.count {
                            let wait = retryDelays[attempt]
                            attempt += 1
                            try? await Task.sleep(for: wait)
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Rate limited, overloaded or temporarily unavailable.
    public static func isTransient(status: Int) -> Bool {
        [408, 425, 429, 500, 502, 503, 504, 520, 522, 524, 529].contains(status)
    }

    public static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed,
                .cannotFindHost, .secureConnectionFailed].contains(error.code)
    }

    /// The server's own wait hint, capped at 20 s.
    static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value), seconds > 0 else { return nil }
        return .milliseconds(Int(min(seconds, 20) * 1000))
    }
}
