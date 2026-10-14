import XCTest
@testable import Mainbrella

@MainActor final class BuilderTests: XCTestCase {
    private var client: BuildClient!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = BuildClient(baseURL: URL(string: "http://localhost:8787")!, token: String(repeating: "a", count: 64), session: URLSession(configuration: config))
    }
    override func tearDown() {
        StubProtocol.handler = nil
        client.session.invalidateAndCancel()
    }
    private static let appID = "11111111-1111-4111-8111-111111111111"
    private static func snapshot(active: Bool = false, revision: Int = 1, text: String = "Creating a frog field guide.") -> Data {
        Data("""
        {"app":{"id":"\(appID)","name":"Frogs","prompt":"Make me a website about frogs","revision":\(revision),"activeTurnId":\(active ? "\"turn\"" : "null"),"preview":null,"turns":[{"id":"turn","prompt":"Make me a website about frogs","mode":"build","status":"\(active ? "running" : "succeeded")","stage":"\(active ? "Writing files" : "Preview ready")","summary":null,"error":null,"model":"@cf/test","activity":[{"id":"message-1","type":"message","text":"\(text)","status":"succeeded"}]}]}}
        """.utf8)
    }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    func testDebugUsesLocalAPI() {
        #if DEBUG
        XCTAssertEqual(ServiceURLs.api.absoluteString, "http://localhost:8787/")
        #else
        XCTAssertEqual(ServiceURLs.api.absoluteString, "https://api.mainbrella.com/")
        #endif
    }
    func testCreateUsesSessionOriginAndIdempotencyAndPreservesPrompt() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8787/build/apps")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://mainbrella.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "mainbrella_session=" + String(repeating: "a", count: 64))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "create-once")
            let body = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: String]
            XCTAssertEqual(body, ["prompt": "Make me a website about frogs", "model": "@cf/test", "effort": "low"])
            return (201, Self.snapshot(active: true))
        }
        let app = try await client.submit(app: nil, prompt: "Make me a website about frogs", model: "@cf/test", effort: "low", key: "create-once")
        XCTAssertTrue(app.building)
    }
    func testUpdateAndPreviewUseExactRevision() async throws {
        let app = try JSONDecoder().decode(BuildSnapshot.self, from: Self.snapshot(revision: 7)).app
        var modes: [String] = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/build/apps/\(Self.appID)/turns")
            let body = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            XCTAssertEqual(body["revision"] as? Int, 7)
            modes.append(body["mode"] as! String)
            if body["mode"] as? String == "preview" {
                XCTAssertNil(body["model"]); XCTAssertNil(body["effort"]); XCTAssertNil(body["prompt"])
            }
            return (200, Self.snapshot(active: true))
        }
        _ = try await client.submit(app: app, prompt: "Add a pond", model: "@cf/test", effort: "low", key: "change")
        _ = try await client.submit(app: app, prompt: nil, model: "@cf/test", effort: "low", key: "preview")
        XCTAssertEqual(modes, ["build", "preview"])
    }
    func testSSEReplacesPartialMessagesAndIgnoresKeepAlive() throws {
        var parser = BuildEventParser()
        XCTAssertNil(try parser.consume(": keep-alive"))
        XCTAssertNil(try parser.consume(""))
        for text in ["Creating", "Creating a frog field guide."] {
            XCTAssertNil(try parser.consume("event: app"))
            XCTAssertNil(try parser.consume("data: " + String(decoding: Self.snapshot(active: true, text: text), as: UTF8.self)))
            let app = try XCTUnwrap(parser.consume(""))
            XCTAssertEqual(app.turns?.first?.activity?.count, 1)
            XCTAssertEqual(app.turns?.first?.activity?.first?.text, text)
        }
        XCTAssertNil(try parser.consume("event: other"))
        XCTAssertNil(try parser.consume("data: ignored"))
        XCTAssertNil(try parser.consume(""))
        XCTAssertNil(try parser.consume("event: app"))
        XCTAssertNil(try parser.consume("data: invalid"))
        XCTAssertThrowsError(try parser.consume(""))
    }
    func testPreviewRestrictsOriginsAndExpiresInMilliseconds() {
        let host = String(repeating: "a", count: 48)
        let valid = BuildApp.Preview(id: "p", url: "https://\(host).mainbrella.dev/", expiresAt: 20_000)
        XCTAssertNotNil(valid.safeURL)
        for url in ["https://mainbrella.dev/", "https://\(host).mainbrella.dev.evil.test/", "https://user:pass@\(host).mainbrella.dev/", "javascript:alert(1)", "https://\(host).mainbrella.dev:444/"] {
            XCTAssertNil(BuildApp.Preview(id: "p", url: url, expiresAt: 20_000).safeURL)
        }
        let app = BuildApp(id: Self.appID, name: "Frogs", prompt: "Frogs", revision: 1, activeTurnId: nil, preview: valid, turns: [])
        XCTAssertNotNil(app.previewURL(at: Date(timeIntervalSince1970: 19)))
        XCTAssertNil(app.previewURL(at: Date(timeIntervalSince1970: 20)))
    }
    func testLostResponseKeepsDraftAndRetriesSameRequestIdentity() async throws {
        var writes: [(String?, Data)] = []
        StubProtocol.handler = { request in
            if request.url?.path == "/build/config" {
                return (200, Data("{\"available\":true,\"model\":\"@cf/test\",\"models\":[],\"maxApps\":50,\"aiBilling\":\"prepaid\"}".utf8))
            }
            if request.httpMethod == "GET" { return (200, Data("{\"apps\":[]}".utf8)) }
            writes.append((request.value(forHTTPHeaderField: "Idempotency-Key"), Self.body(request)))
            if writes.count == 1 { throw URLError(.networkConnectionLost) }
            return (201, Self.snapshot(active: true))
        }
        let store = BuilderStore()
        await store.load(client)
        store.draft = "Make me a website about frogs"
        await store.send(client)
        XCTAssertEqual(store.draft, "Make me a website about frogs")
        XCTAssertNotNil(store.error)
        await store.send(client)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].0, writes[1].0)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: writes[0].1) as! NSDictionary,
                       try JSONSerialization.jsonObject(with: writes[1].1) as! NSDictionary)
        XCTAssertEqual(store.draft, "")
        XCTAssertTrue(store.selected!.building)
        store.reset()
        XCTAssertNil(store.selected); XCTAssertTrue(store.apps.isEmpty); XCTAssertEqual(store.draft, "")
    }
    func testReloadReplacesRemovedModelBeforeRetrying() async throws {
        let workers = "@cf/test"
        let codex = "codex/local-model"
        var currentModel = workers
        var writes: [(key: String?, body: [String: String])] = []
        StubProtocol.handler = { request in
            if request.url?.path == "/build/config" {
                let config: [String: Any] = [
                    "available": true, "model": currentModel, "maxApps": 50, "aiBilling": "included",
                    "models": [["id": currentModel, "name": currentModel, "efforts": ["low"], "defaultEffort": "low"]]
                ]
                return (200, try JSONSerialization.data(withJSONObject: config))
            }
            if request.httpMethod == "GET" { return (200, Data("{\"apps\":[]}".utf8)) }
            writes.append((request.value(forHTTPHeaderField: "Idempotency-Key"),
                           try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: String]))
            if writes.count == 1 { return (400, Data("{\"error\":\"invalid_build_model\"}".utf8)) }
            return (202, Self.snapshot(active: true))
        }
        let store = BuilderStore()
        await store.load(client)
        store.draft = "Make me a website about frogs"
        currentModel = codex
        await store.send(client)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.draft, "Make me a website about frogs")
        await store.load(client)
        XCTAssertEqual(store.model, codex)
        XCTAssertEqual(store.chosenModel?.id, codex)
        XCTAssertEqual(store.effort, "low")
        await store.send(client)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[1].body, ["prompt": "Make me a website about frogs", "model": codex, "effort": "low"])
        XCTAssertNotEqual(writes[0].key, writes[1].key)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.draft, "")
    }
    func testReloadPreservesSupportedSelectionAndReplacesRemovedEffort() async throws {
        var efforts = ["low", "high"]
        StubProtocol.handler = { request in
            if request.url?.path == "/build/config" {
                let config: [String: Any] = [
                    "available": true, "model": "default", "maxApps": 50, "aiBilling": "prepaid",
                    "models": [
                        ["id": "default", "name": "Default", "efforts": ["low"], "defaultEffort": "low"],
                        ["id": "selected", "name": "Selected", "efforts": efforts, "defaultEffort": "low"]
                    ]
                ]
                return (200, try JSONSerialization.data(withJSONObject: config))
            }
            return (200, Data("{\"apps\":[]}".utf8))
        }
        let store = BuilderStore()
        await store.load(client)
        store.model = "selected"
        store.effort = "high"
        await store.load(client)
        XCTAssertEqual(store.model, "selected")
        XCTAssertEqual(store.effort, "high")
        efforts = ["low"]
        await store.load(client)
        XCTAssertEqual(store.model, "selected")
        XCTAssertEqual(store.effort, "low")
    }
    func testRejectedBuildOptionsExplainHowToRecover() {
        for code in ["invalid_build_model", "invalid_build_effort"] {
            let message = BuildError.response(400, code).localizedDescription
            XCTAssertTrue(message.contains("Reconnect"))
            XCTAssertFalse(message.contains("saved work"))
        }
    }
    func testAPIKeyCannotBeUsedAsBuilderSession() {
        let account = AppStore(token: "mb_test", saveToken: { _ in })
        XCTAssertThrowsError(try account.buildAPI)
    }
}
