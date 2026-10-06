import Foundation

enum LiveState: String {
    case paused = "Paused", connecting = "Connecting", live = "Live"
    case reconnecting = "Reconnecting", unavailable = "Unavailable"
    case authenticationRequired = "Update API key"

    var explanation: String? {
        switch self {
        case .reconnecting: return "Live updates disconnected. Reconnecting automatically…"
        case .unavailable: return "This server doesn't support live updates. Pull to refresh."
        case .authenticationRequired: return "Live updates require a valid API key. Update it in Account."
        default: return nil
        }
    }
}

protocol ActivitySocket: Sendable {
    var responseStatus: Int? { get }
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping() async throws
    func cancel()
}

final class NativeActivitySocket: ActivitySocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    var responseStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
    init(client: APIClient) throws {
        task = client.session.webSocketTask(with: try client.activityRequest())
        task.maximumMessageSize = 2048
        task.resume()
    }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

/// Owns one foreground subscription. Backoff and transport heartbeats never fetch data.
@MainActor final class ActivityStream {
    private let makeSocket: (APIClient) throws -> any ActivitySocket
    private let wait: (UInt64) async throws -> Void
    init(makeSocket: @escaping (APIClient) throws -> any ActivitySocket = { try NativeActivitySocket(client: $0) },
         wait: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.makeSocket = makeSocket
        self.wait = wait
    }

    func run(client: APIClient, state: (LiveState) -> Void, event: (ActivityFrame) -> Void) async {
        var failures = 0
        var capabilityChecked = false
        while !Task.isCancelled {
            state(failures == 0 ? .connecting : .reconnecting)
            var socket: (any ActivitySocket)?
            var readyAt: Date?
            do {
                if !capabilityChecked {
                    let capabilities = try await client.capabilities()
                    try Task.checkCancellation()
                    guard capabilities.observability.activityWebSocket else { state(.unavailable); return }
                    capabilityChecked = true
                }
                let connection = try makeSocket(client)
                socket = connection
                try await withTaskCancellationHandler {
                    let heartbeat = Task {
                        do {
                            while !Task.isCancelled {
                                try await Task.sleep(nanoseconds: 25_000_000_000)
                                try Task.checkCancellation()
                                try await connection.ping()
                            }
                        } catch { connection.cancel() }
                    }
                    defer { heartbeat.cancel(); connection.cancel() }
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        try Task.checkCancellation()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        if data == Data("pong".utf8) { continue }
                        guard data.count <= 2048 else { throw APIError.response(0, "activity_frame_too_large") }
                        let frame = try JSONDecoder().decode(ActivityFrame.self, from: data)
                        if frame.type == "ready" {
                            readyAt = Date()
                            state(.live)
                            // Subscribe before loading the snapshot to close the startup gap.
                            event(frame)
                        } else if frame.type == "changed", readyAt != nil {
                            event(frame)
                        }
                    }
                } onCancel: { connection.cancel() }
            } catch {
                socket?.cancel()
                guard !Task.isCancelled else { return }
                let status = socket?.responseStatus ?? (error as? APIError).flatMap {
                    if case .response(let code, _) = $0 { return code }; return nil
                }
                if status == 401 || status == 403 { state(.authenticationRequired); return }
                if let readyAt, Date().timeIntervalSince(readyAt) >= 30 { failures = 0 }
                failures = min(failures + 1, 6)
                state(.reconnecting)
                let seconds = min(pow(2, Double(failures - 1)), 30) + Double.random(in: 0...0.5)
                do { try await wait(UInt64(seconds * 1_000_000_000)) }
                catch { return }
            }
        }
    }
}
