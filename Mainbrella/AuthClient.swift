import Foundation

struct AccountUser: Codable, Equatable {
    let id: String
    let email: String?
    let name: String
}

struct AccountSession {
    let token: String
    let user: AccountUser
}

enum SignInError: LocalizedError {
    case response(String)
    case unavailable
    case invalidSession

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Could not reach Mainbrella sign-in. Check your connection and try again."
        case .invalidSession: return "Could not finish signing you in. Please try again."
        case .response(let code):
            switch code {
            case "invalid_request": return "Enter a valid email and a password of no more than 128 characters."
            case "weak_password": return "Use at least 8 characters for a new password."
            case "invalid_credentials": return "Email or password is incorrect. If you signed up with Google, continue with Google."
            case "identity_conflict": return "This email already has a password account. Continue with email and password."
            case "invalid_google_credential": return "Google could not verify that sign-in. Please try again."
            case "rate_limited": return "Too many attempts. Please wait a minute and try again."
            case "google_unavailable": return "Google sign-in is temporarily unavailable. Try again or continue with email."
            default: return "Sign-in is temporarily unavailable. Please try again."
            }
        }
    }
}

/// Uses the same 30-day account session as the web. Workspace routes accept its
/// opaque token as a Bearer credential, including the activity WebSocket.
struct AuthClient {
    let baseURL: URL
    var session: URLSession = .shared
    private static let cookieName = "mainbrella_session"

    func signInWithEmail(email: String, password: String) async throws -> AccountSession {
        try await signIn(path: "auth/email", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "password": password])
    }

    func signInWithGoogle(credential: String) async throws -> AccountSession {
        try await signIn(path: "auth/google", body: ["credential": credential])
    }

    func currentUser(token: String) async throws -> AccountUser? {
        let (data, response) = try await request("auth/me", token: token)
        if response.statusCode == 401 { return nil }
        try check(response, data: data)
        struct Result: Decodable { let user: AccountUser? }
        return try JSONDecoder().decode(Result.self, from: data).user
    }

    func signOut(token: String) async throws {
        let (data, response) = try await request("auth/logout", method: "POST", token: token)
        try check(response, data: data)
        struct Result: Decodable { let ok: Bool }
        guard try JSONDecoder().decode(Result.self, from: data).ok else { throw SignInError.invalidSession }
    }

    private func signIn(path: String, body: [String: String]) async throws -> AccountSession {
        let (data, response) = try await request(path, method: "POST", body: body)
        try check(response, data: data)
        struct Result: Decodable { let user: AccountUser }
        let user = try JSONDecoder().decode(Result.self, from: data).user
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let key = field.key as? String, let value = field.value as? String { result[key] = value }
        }
        guard let url = response.url,
              let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).first(where: { $0.name == Self.cookieName }),
              cookie.isSecure, cookie.value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              cookie.expiresDate.map({ $0 > Date() }) ?? false else { throw SignInError.invalidSession }
        return AccountSession(token: cookie.value, user: user)
    }

    private func request(_ path: String, method: String = "GET", token: String? = nil,
                         body: [String: String]? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.timeoutInterval = 35
        // Keep account credentials in Keychain, not URLSession's cookie jar.
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("\(Self.cookieName)=\(token)", forHTTPHeaderField: "Cookie") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SignInError.unavailable }
            return (data, response)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw SignInError.unavailable
        }
    }

    private func check(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw SignInError.response((try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "")
        }
    }
}
