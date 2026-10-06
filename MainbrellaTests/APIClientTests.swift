import XCTest
@testable import Mainbrella

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    static let workspace = Workspace(id: "small", name: "Test workspace", status: "running", createdAt: "2026-10-05T12:00:00.000Z", expiresAt: "2026-10-05T13:00:00.000Z")
    var client: APIClient!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = APIClient(baseURL: URL(string: "https://api.mainbrella.com")!, token: "mb_test", session: URLSession(configuration: config))
    }
    override func tearDown() { StubProtocol.handler = nil; client.session.invalidateAndCancel() }
    func testPreviewUsesExactGenerationAndDoesNotRetry() async throws {
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mb_test")
            XCTAssertEqual(request.url?.path, "/containers/previews")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "createdAt" }?.value, Self.workspace.createdAt)
            XCTAssertEqual(query.first { $0.name == "id" }?.value, Self.workspace.id)
            return (503, Data("{\"error\":\"preview_reconciliation_required\",\"previewId\":\"lost\"}".utf8))
        }
        do { _ = try await client.createPreview(Self.workspace, port: 3000); XCTFail("Expected a failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cleanup")) }
        XCTAssertEqual(calls, 1)
    }
    func testPreviewDecodesOneTimeURLAndMillisecondExpiry() async throws {
        StubProtocol.handler = { _ in (201, Data("{\"id\":\"grant\",\"port\":3000,\"createdAt\":\"2026-10-05T12:00:00.000Z\",\"expiresAt\":1791202500000,\"url\":\"https://protected.mainbrella.dev/\"}".utf8)) }
        let grant = try await client.createPreview(Self.workspace, port: 3000)
        XCTAssertEqual(grant.url?.scheme, "https")
        XCTAssertEqual(grant.expiresAt, 1791202500000)
    }
    func testOversizedUploadNeverReachesNetwork() async {
        StubProtocol.handler = { _ in XCTFail("Must reject locally"); return (200, Data()) }
        do { try await client.upload(Data(count: 1_048_577), path: "/workspace/inbox/image.jpg", workspace: Self.workspace); XCTFail("Must reject oversize") }
        catch { XCTAssertTrue(error is APIError) }
    }
    func testGenerationAndFilePathAreEncodedWithoutChangingIdentity() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "path" }?.value, "/workspace/inbox/a & b.jpg")
            return (200, Data("{}".utf8))
        }
        try await client.upload(Data([1, 2, 3]), path: "/workspace/inbox/a & b.jpg", workspace: Self.workspace)
    }
}

@MainActor final class AppStoreTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
    }
    override func tearDown() { StubProtocol.handler = nil; session.invalidateAndCancel() }

    func testNoCredentialStartsEmptyAndDoesNotRequestData() async throws {
        StubProtocol.handler = { _ in XCTFail("No request without credentials"); return (401, Data()) }
        let store = AppStore(token: "", session: session, saveToken: { _ in })
        XCTAssertFalse(store.connected)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertTrue(store.grants.isEmpty)
        XCTAssertNil(store.preview)
        await store.refresh()
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.loading)
        XCTAssertThrowsError(try store.api)
    }

    func testConnectionLoadsOnlyAPIDataAndDisconnectClearsIt() async throws {
        let workspace = APIClientTests.workspace
        let workspaceJSON = try JSONEncoder().encode(["containers": [workspace]])
        var paths: [String] = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.mainbrella.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mb_test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let path = request.url!.path
            paths.append(path)
            switch path {
            case "/containers": return (200, workspaceJSON)
            case "/containers/executions": return (200, Data("{\"executions\":[{\"id\":\"execution\",\"status\":\"failed\",\"exitCode\":1}]}".utf8))
            case "/containers/previews": return (200, Data("{\"previews\":[{\"id\":\"grant\",\"port\":3000,\"createdAt\":\"2026-10-05T12:00:00.000Z\",\"expiresAt\":1791202500000}]}".utf8))
            default: XCTFail("Unexpected endpoint"); return (404, Data())
            }
        }
        var savedKeys: [String] = []
        let store = AppStore(token: "", session: session, saveToken: { savedKeys.append($0) })
        let connected = await store.connect(token: " mb_test ")
        XCTAssertTrue(connected)
        XCTAssertTrue(store.connected)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.workspaces, [workspace])
        XCTAssertEqual(store.jobs[workspace.id]?.first?.status, "failed")
        XCTAssertEqual(store.grants[workspace.id]?.first?.port, 3000)
        XCTAssertNil(store.preview)
        XCTAssertEqual(paths.count, 4)
        store.disconnect()
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertTrue(store.grants.isEmpty)
        XCTAssertEqual(savedKeys, ["mb_test", ""])
        await store.refresh()
        XCTAssertEqual(paths.count, 4)
    }

    func testRejectedKeyNeverConnectsOrPopulatesState() async {
        StubProtocol.handler = { _ in (401, Data("{\"error\":\"not_authenticated\"}".utf8)) }
        let store = AppStore(token: "", session: session, saveToken: { _ in XCTFail("Do not save rejected key") })
        let connected = await store.connect(token: "mb_rejected")
        XCTAssertFalse(connected)
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNotNil(store.error)
    }

    func testFailedRefreshIsNotReportedAsAnEmptySuccessfulLoad() async {
        StubProtocol.handler = { _ in (503, Data("{\"error\":\"containers_unavailable\"}".utf8)) }
        let store = AppStore(token: "mb_saved", session: session, saveToken: { _ in })
        await store.refresh()
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertNotNil(store.syncError)
    }
}
