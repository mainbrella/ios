import XCTest
import UniformTypeIdentifiers
import Combine
@testable import Mainbrella

@MainActor final class ShareTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() { StubProtocol.handler = nil; session.invalidateAndCancel() }

    func testLinkAndTextArePreservedAndDuplicatesAreRemoved() async throws {
        let url = URL(string: "https://example.com/project?q=a%20b#issue")!
        let payload = try await SharePayload.load([
            NSItemProvider(object: url as NSURL), NSItemProvider(object: "Investigate the layout" as NSString),
            NSItemProvider(object: url as NSURL)
        ])
        XCTAssertEqual(payload.text, url.absoluteString + "\n\nInvestigate the layout")
        XCTAssertNil(payload.attachment)
    }

    func testPhotoIsDownsampledAndEncodedWithinTheProductionLimit() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1000), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        }
        let payload = try await SharePayload.load([NSItemProvider(object: image)])
        XCTAssertEqual(payload.image?.size.width, 2048)
        XCTAssertLessThanOrEqual(try XCTUnwrap(payload.attachment).count, 1_048_576)
        XCTAssertEqual(payload.text, "")
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(payload.attachment)))
    }

    func testMixedUnsupportedShareAndLongTextFailWithoutDroppingContent() async {
        for providers in [
            [NSItemProvider(object: "Useful text" as NSString), NSItemProvider(object: URL(fileURLWithPath: "/tmp/archive.zip") as NSURL)],
            [NSItemProvider(object: String(repeating: "a", count: 262_145) as NSString)],
            []
        ] {
            do { _ = try await SharePayload.load(providers); XCTFail("Unsupported input accepted") }
            catch { XCTAssertTrue(error is ShareFailure) }
        }
    }

    func testDisconnectedShareNeverReadsTheAccount() async {
        StubProtocol.handler = { _ in XCTFail("No unauthenticated requests"); return (401, Data()) }
        let store = ShareStore(token: "", session: session)
        await store.followActivity(); await store.refresh()
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.canSend)
    }

    func testUnsupportedStreamStillLoadsSnapshotAndOffersManualRefresh() async {
        var reads = 0
        StubProtocol.handler = { request in
            if request.url?.path == "/capabilities" { return (200, Data(#"{"observability":{"activityWebSocket":false}}"#.utf8)) }
            reads += 1
            return (200, try JSONEncoder().encode(["containers": [APIClientTests.workspace]]))
        }
        let store = ShareStore(token: "mb_test", session: session)
        await store.followActivity()
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.workspaces, [APIClientTests.workspace])
        XCTAssertEqual(store.liveState, .unavailable)
        await store.refresh()
        XCTAssertEqual(reads, 2)
    }

    func testChangedGenerationClearsSelectionFromLiveWorkspaceEvent() async {
        let original = APIClientTests.workspace
        var workspace = original
        let socket = TestSocket()
        socket.push(.success(.string(#"{"type":"ready"}"#)))
        StubProtocol.handler = { request in
            if request.url?.path == "/capabilities" { return (200, Data(#"{"observability":{"activityWebSocket":true}}"#.utf8)) }
            return (200, try JSONEncoder().encode(["containers": [workspace]]))
        }
        let store = ShareStore(token: "mb_test", session: session, activity: ActivityStream(makeSocket: { _ in socket }))
        let firstRead = expectation(description: "Initial snapshot")
        let replacementRead = expectation(description: "Replacement snapshot")
        let observer = store.$workspaces.dropFirst().sink { spaces in
            if spaces.first?.createdAt == original.createdAt { firstRead.fulfill() }
            else if spaces.first != nil { replacementRead.fulfill() }
        }
        defer { observer.cancel() }
        let task = Task { await store.followActivity() }
        await fulfillment(of: [firstRead], timeout: 3)
        store.selection = original
        workspace = Workspace(id: original.id, name: original.name, status: "running", createdAt: "2026-10-05T14:00:00.000Z", expiresAt: original.expiresAt)
        socket.push(.success(.string(#"{"type":"changed","resource":"containers"}"#)))
        await fulfillment(of: [replacementRead], timeout: 3)
        XCTAssertNil(store.selection)
        XCTAssertFalse(store.canSend)
        task.cancel(); await task.value
    }

    func testUnchangedRetryReusesCompletionBytesAndEditingCreatesANewMessage() async throws {
        let workspace = APIClientTests.workspace
        var metadata: [(String, Data)] = []
        var fail = true
        StubProtocol.handler = { request in
            if request.url?.path == "/containers" { return (200, try JSONEncoder().encode(["containers": [workspace]])) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let path = query.first(where: { $0.name == "path" })?.value, path.hasSuffix(".json") {
                metadata.append((path, Self.body(request)))
                return (fail ? 503 : 200, Data("{}".utf8))
            }
            return (200, Data("{}".utf8))
        }
        let store = ShareStore(token: "mb_test", session: session, readToken: { "mb_test" })
        await store.prepare([NSItemProvider(object: "Shared source" as NSString)])
        await store.refresh()
        store.instruction = " Investigate this "
        await store.send(); await store.send()
        XCTAssertFalse(store.sent)
        XCTAssertEqual(metadata.count, 2)
        XCTAssertEqual(metadata[0].0, metadata[1].0)
        XCTAssertEqual(metadata[0].1, metadata[1].1)
        let saved = try JSONDecoder().decode(InboxMessage.self, from: metadata[0].1)
        XCTAssertEqual(saved.source, "ios-share")
        XCTAssertEqual(saved.instruction, "Investigate this")
        XCTAssertEqual(saved.text, "Shared source")
        XCTAssertEqual(saved.generation, workspace.createdAt)
        store.instruction = "Use the new instruction"
        fail = false
        await store.send()
        XCTAssertTrue(store.sent)
        XCTAssertNotEqual(metadata[0].0, metadata[2].0)
        XCTAssertFalse(store.canSend)
    }

    func testAccountChangePreventsUploadingIntoThePreviousAccount() async {
        var uploads = 0
        StubProtocol.handler = { request in
            if request.url?.path == "/containers" { return (200, try JSONEncoder().encode(["containers": [APIClientTests.workspace]])) }
            uploads += 1; return (200, Data("{}".utf8))
        }
        let store = ShareStore(token: "mb_old", session: session, readToken: { "mb_new" })
        await store.prepare([NSItemProvider(object: "source" as NSString)])
        await store.refresh(); store.instruction = "Check this"
        await store.send()
        XCTAssertEqual(uploads, 0)
        XCTAssertFalse(store.sent)
        XCTAssertTrue(store.failure?.contains("account changed") == true)
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
