import XCTest
@testable import Mainbrella

@MainActor final class AuthTests: XCTestCase {
    private var session: URLSession!
    private var auth: AuthClient!
    private let token = String(repeating: "a", count: 64)
    private let userJSON = #"{"user":{"id":"account","email":"person@example.com","name":"Person"}}"#

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
        auth = AuthClient(baseURL: ServiceURLs.api, session: session)
        StubProtocol.responseHeaders = ["Set-Cookie": "mainbrella_session=\(token); Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000"]
    }

    override func tearDown() {
        StubProtocol.handler = nil; StubProtocol.responseHeaders = nil
        session.invalidateAndCancel()
    }

    func testEmailUsesWebEndpointAndKeepsPasswordUnchanged() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/email")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body = try JSONDecoder().decode([String: String].self, from: Self.body(request))
            XCTAssertEqual(body, ["email": "person@example.com", "password": " spaced password "])
            return (200, Data(self.userJSON.utf8))
        }
        let result = try await auth.signInWithEmail(email: " Person@Example.com \n", password: " spaced password ")
        XCTAssertEqual(result.token, token)
        XCTAssertEqual(result.user.email, "person@example.com")
        XCTAssertNil(session.configuration.httpCookieStorage?.cookies?.first { $0.name == "mainbrella_session" })
    }

    func testGoogleSendsIDTokenToWebEndpoint() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/google")
            let body = try JSONDecoder().decode([String: String].self, from: Self.body(request))
            XCTAssertEqual(body, ["credential": "google-id-token"])
            return (200, Data(self.userJSON.utf8))
        }
        let result = try await auth.signInWithGoogle(credential: "google-id-token")
        XCTAssertEqual(result.token, token)
    }

    func testSessionReadAndLogoutUseExplicitCookie() async throws {
        var paths: [String] = []
        StubProtocol.handler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "mainbrella_session=\(self.token)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            return (200, Data((request.url!.path == "/auth/me" ? self.userJSON : #"{"ok":true}"#).utf8))
        }
        let user = try await auth.currentUser(token: token)
        XCTAssertEqual(user?.id, "account")
        try await auth.signOut(token: token)
        XCTAssertEqual(paths, ["/auth/me", "/auth/logout"])
    }

    func testLoginWithoutValidSecureSessionCookieIsRejected() async {
        StubProtocol.handler = { _ in (200, Data(self.userJSON.utf8)) }
        for cookie in ["", "mainbrella_session=bad; Secure; Max-Age=1000",
                       "mainbrella_session=\(token); Max-Age=1000",
                       "mainbrella_session=\(token); Secure; Max-Age=0"] {
            StubProtocol.responseHeaders = ["Set-Cookie": cookie]
            do {
                _ = try await auth.signInWithGoogle(credential: "id-token")
                XCTFail("Must reject missing, malformed, insecure or expired credentials")
            } catch { XCTAssertTrue(error is SignInError) }
        }
    }

    func testAuthErrorsHaveUsefulMessagesWithoutRawServerDetails() async {
        for (status, code, message) in [(401, "invalid_credentials", "incorrect"), (409, "identity_conflict", "password account"),
                                        (429, "rate_limited", "wait a minute"), (400, "weak_password", "8 characters"),
                                        (503, "internal secret", "temporarily unavailable")] {
            StubProtocol.handler = { _ in (status, Data("{\"error\":\"\(code)\"}".utf8)) }
            do { _ = try await auth.signInWithEmail(email: "person@example.com", password: "password"); XCTFail("Must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains(message)) }
        }
    }

    func testSignInSucceedsBeforeAccountHasAPlan() async {
        var saved: [String] = []
        StubProtocol.handler = { request in
            switch request.url!.path {
            case "/auth/email": return (200, Data(self.userJSON.utf8))
            case "/containers":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.token)")
                return (402, Data(#"{"error":"subscription_required"}"#.utf8))
            default: XCTFail("Unexpected endpoint"); return (404, Data())
            }
        }
        let store = AppStore(token: "", session: session, saveToken: { saved.append($0) })
        let signedIn = await store.signInWithEmail(email: "person@example.com", password: "password")
        XCTAssertTrue(signedIn)
        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.user?.id, "account")
        XCTAssertEqual(saved, [token])
        XCTAssertNotNil(store.syncError)
        XCTAssertNil(store.authenticationError)
    }

    func testGoogleCancellationDoesNotAuthenticateOrShowError() async {
        StubProtocol.handler = { _ in XCTFail("No request after Google cancellation"); return (500, Data()) }
        let store = AppStore(token: "", session: session, saveToken: { _ in XCTFail("No save") })
        let signedIn = await store.signInWithGoogle { throw CancellationError() }
        XCTAssertFalse(signedIn)
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.authenticationBusy)
        XCTAssertNil(store.authenticationError)
    }

    func testRestoresSavedSessionWithoutNewLogin() async {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/me")
            return (200, Data(self.userJSON.utf8))
        }
        let store = AppStore(token: token, session: session, saveToken: { _ in XCTFail("No new credential") })
        await store.restoreAccount()
        XCTAssertEqual(store.user?.email, "person@example.com")
        XCTAssertTrue(store.connected)
    }

    func testExpiredSessionClearsSharedCredentialAndReturnsToSignIn() async {
        var saved: [String] = []
        StubProtocol.handler = { _ in (200, Data(#"{"user":null}"#.utf8)) }
        let store = AppStore(token: token, session: session, saveToken: { saved.append($0) })
        await store.restoreAccount()
        XCTAssertFalse(store.connected)
        XCTAssertEqual(saved, [""])
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNotNil(store.authenticationError)
    }

    func testUnavailableSessionCheckKeepsSavedAccount() async {
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let store = AppStore(token: token, session: session, saveToken: { _ in XCTFail("Keep credential") })
        await store.restoreAccount()
        XCTAssertTrue(store.connected)
        XCTAssertNotNil(store.syncError)
    }

    func testSignOutRevokesSessionBeforeClearingSharedCredential() async {
        var revoked = false
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/logout")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "mainbrella_session=\(self.token)")
            revoked = true
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        let store = AppStore(token: token, session: session, saveToken: { value in
            XCTAssertTrue(revoked); XCTAssertEqual(value, "")
        })
        let signedOut = await store.signOut()
        XCTAssertTrue(signedOut)
        XCTAssertFalse(store.connected)
        XCTAssertNil(store.user)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    func testFailedSignOutKeepsSavedAccount() async {
        StubProtocol.handler = { _ in (503, Data(#"{"error":"auth_unavailable"}"#.utf8)) }
        let store = AppStore(token: token, session: session, saveToken: { _ in XCTFail("Keep credential") })
        let signedOut = await store.signOut()
        XCTAssertFalse(signedOut)
        XCTAssertTrue(store.connected)
        XCTAssertNotNil(store.authenticationError)
    }

    func testKeychainFailureRevokesUnsavedSession() async {
        var revoked = false
        StubProtocol.handler = { request in
            if request.url!.path == "/auth/logout" { revoked = true; return (200, Data(#"{"ok":true}"#.utf8)) }
            return (200, Data(self.userJSON.utf8))
        }
        let store = AppStore(token: "", session: session, saveToken: { _ in throw APIError.response(0, "keychain") })
        let signedIn = await store.signInWithEmail(email: "person@example.com", password: "password")
        XCTAssertFalse(signedIn)
        XCTAssertTrue(revoked)
        XCTAssertFalse(store.connected)
        XCTAssertNotNil(store.authenticationError)
    }

    private nonisolated static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}
