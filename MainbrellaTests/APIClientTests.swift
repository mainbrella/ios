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
            XCTAssertEqual(query.first { $0.name == "createdAt" }?.value, Workspace.demo.createdAt)
            XCTAssertEqual(query.first { $0.name == "id" }?.value, Workspace.demo.id)
            return (503, Data("{\"error\":\"preview_reconciliation_required\",\"previewId\":\"lost\"}".utf8))
        }
        do { _ = try await client.createPreview(.demo, port: 3000); XCTFail("Expected a failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cleanup")) }
        XCTAssertEqual(calls, 1)
    }
    func testPreviewDecodesOneTimeURLAndMillisecondExpiry() async throws {
        StubProtocol.handler = { _ in (201, Data("{\"id\":\"grant\",\"port\":3000,\"createdAt\":\"2026-10-05T12:00:00.000Z\",\"expiresAt\":1791202500000,\"url\":\"https://protected.mainbrella.dev/\"}".utf8)) }
        let grant = try await client.createPreview(.demo, port: 3000)
        XCTAssertEqual(grant.url?.scheme, "https")
        XCTAssertEqual(grant.expiresAt, 1791202500000)
    }
    func testOversizedUploadNeverReachesNetwork() async {
        StubProtocol.handler = { _ in XCTFail("Must reject locally"); return (200, Data()) }
        do { try await client.upload(Data(count: 1_048_577), path: "/workspace/inbox/image.jpg", workspace: .demo); XCTFail("Must reject oversize") }
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
        try await client.upload(Data([1, 2, 3]), path: "/workspace/inbox/a & b.jpg", workspace: .demo)
    }
}
