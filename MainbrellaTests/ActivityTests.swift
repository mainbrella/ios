import XCTest
import Combine
@testable import Mainbrella

final class TestSocket: ActivitySocket, @unchecked Sendable {
    var responseStatus: Int?
    private let lock = NSLock()
    private var frames: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var canceled = false

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if canceled {
                lock.unlock(); continuation.resume(throwing: CancellationError())
            } else if !frames.isEmpty {
                let value = frames.removeFirst()
                lock.unlock(); continuation.resume(with: value)
            } else {
                receiver = continuation; lock.unlock()
            }
        }
    }
    func ping() async throws {}
    func push(_ value: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        if let receiver {
            self.receiver = nil; lock.unlock(); receiver.resume(with: value)
        } else { frames.append(value); lock.unlock() }
    }
    func cancel() {
        lock.lock(); canceled = true
        let receiver = self.receiver; self.receiver = nil
        lock.unlock(); receiver?.resume(throwing: CancellationError())
    }
}

private final class DeferredActivityProtocol: URLProtocol {
    static var handler: ((URLRequest, @escaping (Data) -> Void) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request, { [weak self] data in
            guard let self else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        })
    }
    override func stopLoading() {}
}

@MainActor final class ActivityTests: XCTestCase {
    private var session: URLSession!
    private var client: APIClient!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
        client = APIClient(baseURL: ServiceURLs.api, token: "mb_test", session: session)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/capabilities")
            return (200, Data(#"{"observability":{"activityWebSocket":true}}"#.utf8))
        }
    }
    override func tearDown() { StubProtocol.handler = nil; session.invalidateAndCancel() }

    func testWebSocketKeepsCredentialsOutOfURL() throws {
        let request = try client.activityRequest()
        XCTAssertEqual(request.url?.absoluteString, "wss://api.mainbrella.com/containers/activity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mb_test")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
    }

    func testReconnectWaitsForReadyAndCancellationClosesSocket() async {
        let first = TestSocket(), second = TestSocket()
        first.push(.success(.string(#"{"type":"ready"}"#)))
        first.push(.failure(URLError(.networkConnectionLost)))
        // A change before ready must not be delivered.
        second.push(.success(.string(#"{"type":"changed","resource":"previews","containerId":"small","createdAt":"2026-10-05T12:00:00.000Z"}"#)))
        second.push(.success(.string(#"{"type":"ready"}"#)))
        let attached = expectation(description: "Both ready frames delivered")
        attached.expectedFulfillmentCount = 2
        var sockets = [first, second]
        var states: [LiveState] = []
        var delays: [UInt64] = []
        var frames: [ActivityFrame] = []
        let stream = ActivityStream(makeSocket: { _ in sockets.removeFirst() }, wait: { delays.append($0) })
        let task = Task {
            await stream.run(client: client, state: { states.append($0) }, event: {
                frames.append($0); attached.fulfill()
            })
        }
        await fulfillment(of: [attached], timeout: 3)
        task.cancel(); await task.value
        XCTAssertEqual(frames.map(\.type), ["ready", "ready"])
        XCTAssertEqual(states, [.connecting, .live, .reconnecting, .reconnecting, .live])
        XCTAssertEqual(delays.count, 1)
        XCTAssertTrue((1_000_000_000...1_500_000_000).contains(delays[0]))
        do { _ = try await second.receive(); XCTFail("Canceled socket remained open") }
        catch {}
    }

    func testUnsupportedServerDoesNotAttemptSocketOrRetry() async {
        StubProtocol.handler = { _ in (200, Data(#"{"observability":{"activityWebSocket":false}}"#.utf8)) }
        var states: [LiveState] = []
        let stream = ActivityStream(makeSocket: { _ in XCTFail("Unsupported socket"); return TestSocket() },
            wait: { _ in XCTFail("Unsupported server must not retry") })
        await stream.run(client: client, state: { states.append($0) }, event: { _ in XCTFail("No event") })
        XCTAssertEqual(states, [.connecting, .unavailable])
    }

    func testRejectedWebSocketKeyStopsReconnecting() async {
        let socket = TestSocket()
        socket.responseStatus = 401
        socket.push(.failure(URLError(.badServerResponse)))
        var states: [LiveState] = []
        let stream = ActivityStream(makeSocket: { _ in socket }, wait: { _ in XCTFail("Do not retry rejected key") })
        await stream.run(client: client, state: { states.append($0) }, event: { _ in XCTFail("No event") })
        XCTAssertEqual(states, [.connecting, .authenticationRequired])
    }

    func testExecutionHintOnlyReadsThatResourceAndIgnoresOldGeneration() async throws {
        let workspace = APIClientTests.workspace
        let spaces = try JSONEncoder().encode(["containers": [workspace]])
        var paths: [String] = []
        var status = "running"
        StubProtocol.handler = { request in
            let path = request.url!.path
            paths.append(path)
            switch path {
            case "/containers": return (200, spaces)
            case "/containers/executions": return (200, Data("{\"executions\":[{\"id\":\"job\",\"status\":\"\(status)\"}]}".utf8))
            case "/containers/previews": return (200, Data(#"{"previews":[]}"#.utf8))
            default: XCTFail("Unexpected request"); return (404, Data())
            }
        }
        let store = AppStore(token: "mb_test", session: session, saveToken: { _ in })
        await store.refresh()
        paths = []; status = "succeeded"
        let changed = expectation(description: "Execution updated")
        let subscription = store.$jobs.dropFirst().sink { jobs in
            if jobs[workspace.id]?.first?.status == "succeeded" { changed.fulfill() }
        }
        let frame = try JSONDecoder().decode(ActivityFrame.self, from: Data("{\"type\":\"changed\",\"resource\":\"executions\",\"containerId\":\"\(workspace.id)\",\"createdAt\":\"\(workspace.createdAt)\",\"executionId\":\"job\"}".utf8))
        store.receiveActivity(frame)
        await fulfillment(of: [changed], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(paths, ["/containers/executions"])
        XCTAssertEqual(store.executionVersions[workspace.id], 2)
        let old = try JSONDecoder().decode(ActivityFrame.self, from: Data(#"{"type":"changed","resource":"executions","containerId":"small","createdAt":"2026-10-04T12:00:00.000Z"}"#.utf8))
        store.receiveActivity(old)
        await Task.yield()
        XCTAssertEqual(paths, ["/containers/executions"])
    }

    func testPreviewRevocationHintDismissesOpenPreview() async throws {
        let workspace = APIClientTests.workspace
        let spaces = try JSONEncoder().encode(["containers": [workspace]])
        StubProtocol.handler = { request in
            switch request.url!.path {
            case "/containers": return (200, spaces)
            case "/containers/executions": return (200, Data(#"{"executions":[]}"#.utf8))
            default: return (200, Data(#"{"previews":[]}"#.utf8))
            }
        }
        let store = AppStore(token: "mb_test", session: session, saveToken: { _ in })
        await store.refresh()
        store.preview = PreviewSession(grantID: "grant", workspace: workspace,
            url: URL(string: "https://protected.mainbrella.dev")!, expiresAt: Date().addingTimeInterval(300))
        let closed = expectation(description: "Revoked preview dismissed")
        let subscription = store.$preview.dropFirst().sink { if $0 == nil { closed.fulfill() } }
        store.receiveActivity(try JSONDecoder().decode(ActivityFrame.self, from: Data("{\"type\":\"changed\",\"resource\":\"previews\",\"containerId\":\"\(workspace.id)\",\"createdAt\":\"\(workspace.createdAt)\"}".utf8)))
        await fulfillment(of: [closed], timeout: 3)
        subscription.cancel()
        XCTAssertNil(store.preview)
    }

    func testHintsDuringSnapshotAreRetainedAndBurstsAreCoalesced() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredActivityProtocol.self]
        let deferredSession = URLSession(configuration: config)
        defer { deferredSession.invalidateAndCancel(); DeferredActivityProtocol.handler = nil }
        let workspace = APIClientTests.workspace
        let spaces = try JSONEncoder().encode(["containers": [workspace]])
        let firstRead = expectation(description: "First invalidation read in flight")
        var holdRead = false
        var reads = 0
        var reply: ((Data) -> Void)?
        DeferredActivityProtocol.handler = { request, respond in
            switch request.url!.path {
            case "/containers": respond(spaces)
            case "/containers/previews": respond(Data(#"{"previews":[]}"#.utf8))
            default:
                if holdRead {
                    reads += 1
                    if reads == 1 { reply = respond; firstRead.fulfill() }
                    else { respond(Data(#"{"executions":[{"id":"job","status":"succeeded"}]}"#.utf8)) }
                } else { respond(Data(#"{"executions":[{"id":"job","status":"running"}]}"#.utf8)) }
            }
        }
        let store = AppStore(token: "mb_test", session: deferredSession, saveToken: { _ in })
        await store.refresh()
        holdRead = true
        let frame = try JSONDecoder().decode(ActivityFrame.self, from: Data("{\"type\":\"changed\",\"resource\":\"executions\",\"containerId\":\"\(workspace.id)\",\"createdAt\":\"\(workspace.createdAt)\"}".utf8))
        store.receiveActivity(frame)
        await fulfillment(of: [firstRead], timeout: 3)
        XCTAssertTrue(store.loading)
        let finished = expectation(description: "Queued invalidations repaired stale read")
        let subscription = store.$jobs.dropFirst().sink {
            if $0[workspace.id]?.first?.status == "succeeded" { finished.fulfill() }
        }
        for _ in 0..<5 { store.receiveActivity(frame) }
        reply?(Data(#"{"executions":[{"id":"job","status":"running"}]}"#.utf8))
        await fulfillment(of: [finished], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(store.jobs[workspace.id]?.first?.status, "succeeded")
    }

    func testUnavailableStatePersistsAfterSubscriptionReturns() async {
        StubProtocol.handler = { request in
            if request.url!.path == "/capabilities" {
                return (200, Data(#"{"observability":{"activityWebSocket":false}}"#.utf8))
            }
            return (200, Data(#"{"containers":[]}"#.utf8))
        }
        let store = AppStore(token: "mb_test", session: session, saveToken: { _ in })
        await store.followActivity()
        await store.refresh()
        XCTAssertEqual(store.liveState, .unavailable)
        XCTAssertTrue(store.hasLoaded)
    }

    func testDisconnectClosesForegroundSubscriptionImmediately() async {
        StubProtocol.handler = { request in
            if request.url!.path == "/capabilities" {
                return (200, Data(#"{"observability":{"activityWebSocket":true}}"#.utf8))
            }
            return (200, Data(#"{"containers":[]}"#.utf8))
        }
        let socket = TestSocket()
        socket.push(.success(.string(#"{"type":"ready"}"#)))
        let stream = ActivityStream(makeSocket: { _ in socket })
        let store = AppStore(token: "mb_test", session: session, saveToken: { _ in }, activity: stream)
        let ready = expectation(description: "Foreground subscription attached")
        let subscription = store.$liveState.sink { if $0 == .live { ready.fulfill() } }
        let task = Task { await store.followActivity() }
        await fulfillment(of: [ready], timeout: 3)
        await store.refresh()
        store.disconnect()
        await task.value
        subscription.cancel()
        XCTAssertFalse(store.connected)
        XCTAssertEqual(store.liveState, .paused)
        XCTAssertTrue(store.workspaces.isEmpty)
        do { _ = try await socket.receive(); XCTFail("Disconnected account left socket open") }
        catch {}
    }
}
