import Foundation

struct BuildModel: Decodable, Identifiable {
    let id: String
    let name: String
    let efforts: [String]
    let defaultEffort: String
}

struct BuildConfig: Decodable {
    let available: Bool
    let model: String
    let models: [BuildModel]?
    let maxApps: Int
    let aiBilling: String
}

struct BuildActivity: Decodable, Identifiable {
    let id: String
    let type: String
    let text: String
    let status: String
    let explanation: String?
}

struct BuildTurn: Decodable, Identifiable {
    let id: String
    let prompt: String
    let mode: String
    let status: String
    let stage: String
    let summary: String?
    let error: String?
    let errorExplanation: String?
    let model: String
    let activity: [BuildActivity]?
    var running: Bool { status == "queued" || status == "running" }
}

struct BuildApp: Decodable, Identifiable {
    struct Preview: Decodable {
        let id: String
        let url: String
        let expiresAt: Double
        var safeURL: URL? {
            guard let value = URL(string: url), value.user == nil, value.password == nil,
                  let host = value.host else { return nil }
            if value.scheme == "https", value.port == nil,
               host.range(of: "^[a-f0-9]{48}\\.mainbrella\\.dev$", options: .regularExpression) != nil { return value }
            #if DEBUG
            if value.scheme == "http",
               host.range(of: "^[a-f0-9]{48}\\.localhost$", options: .regularExpression) != nil { return value }
            #endif
            return nil
        }
    }
    let id: String
    let name: String
    let prompt: String
    let revision: Int
    let activeTurnId: String?
    let preview: Preview?
    let turns: [BuildTurn]?
    var building: Bool { activeTurnId != nil }
    var latestTurn: BuildTurn? { turns?.last }
    func previewURL(at date: Date = Date()) -> URL? {
        guard let preview, preview.expiresAt > date.timeIntervalSince1970 * 1000 else { return nil }
        return preview.safeURL
    }
}

struct BuildSnapshot: Decodable { let app: BuildApp }

/// Incremental SSE parsing. An app event replaces a snapshot; it never appends
/// duplicate messages. Comments and unrelated events do not change the app.
struct BuildEventParser {
    private var event = ""
    private var data: [String] = []
    private var size = 0
    mutating func consume(_ line: String) throws -> BuildApp? {
        if line.isEmpty {
            defer { event = ""; data = []; size = 0 }
            guard event == "app", !data.isEmpty else { return nil }
            return try JSONDecoder().decode(BuildSnapshot.self, from: Data(data.joined(separator: "\n").utf8)).app
        }
        if line.hasPrefix(":") { return nil }
        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let raw = fields.count > 1 ? String(fields[1]) : ""
        let value = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
        switch fields[0] {
        case "event": event = value
        case "data":
            size += value.utf8.count
            guard size <= 4_194_304 else { throw BuildError.invalidProgress }
            data.append(value)
        default: break
        }
        return nil
    }
}

enum BuildError: LocalizedError {
    case accountRequired, invalidProgress, response(Int, String)
    var errorDescription: String? {
        switch self {
        case .accountRequired: return "Sign in with Google or email in Account to build websites. API keys only connect to workspaces."
        case .invalidProgress: return "Build progress couldn't be read. Reconnect to see the latest progress."
        case .response(let status, let code):
            if status == 401 { return "Your sign-in expired. Sign in again in Account." }
            switch code {
            case "subscription_required", "insufficient_balance": return "Add prepaid balance at mainbrella.com to build and run websites."
            case "spend_limit_exceeded": return "Your monthly spending limit cannot cover this build. Update your limit in Billing."
            case "build_busy": return "Another build is running. Wait for it to finish."
            case "revision_conflict": return "This website changed elsewhere. Reconnect before sending your change."
            case "build_app_limit": return "You've reached the saved website limit. Manage your websites on the web."
            case "build_turn_limit": return "This website has reached its build limit. Start a new website."
            case "build_unavailable", "build_model_unpriced": return "Build is temporarily unavailable. Try again shortly."
            case "app_not_found": return "This website is no longer available. Choose another website."
            case "invalid_request": return "Enter a prompt of 1–6,000 characters and try again."
            case "invalid_build_model", "invalid_build_effort": return "Build model options changed. Reconnect to refresh them, then try again."
            case "storage_funding_required": return "Renew storage funding in Billing to continue building."
            case "build_budget_exceeded": return "The build reached its limit before verification finished. Your source is saved; ask for a smaller change."
            case "build_check_failed": return "The website didn't pass its build check. Ask Build to fix the errors."
            case "preview_start_failed": return "The website built, but its preview couldn't start. Try starting the preview again."
            default: return "Build couldn't complete this request. Your saved work is retained. Try again shortly."
            }
        }
    }
}

struct BuildClient {
    private struct Failure: Decodable { let error: String }
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, key: String? = nil, stream: Bool = false) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("build/" + path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("mainbrella_session=\(token)", forHTTPHeaderField: "Cookie")
        // Builder writes require a trusted web origin, also for native clients.
        request.setValue("https://mainbrella.com", forHTTPHeaderField: "Origin")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        request.timeoutInterval = stream ? 75 : 35
        return request
    }
    private func read<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, key: String? = nil) async throws -> T {
        let (data, response) = try await session.data(for: makeRequest(path, method: method, body: body, key: key))
        guard let http = response as? HTTPURLResponse else { throw BuildError.invalidProgress }
        guard (200..<300).contains(http.statusCode) else {
            throw BuildError.response(http.statusCode, (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func config() async throws -> BuildConfig { try await read("config") }
    func apps() async throws -> [BuildApp] {
        struct Response: Decodable { let apps: [BuildApp] }
        let response: Response = try await read("apps")
        return response.apps
    }
    private func path(_ id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw BuildError.invalidProgress }
        return "apps/" + id
    }
    func app(_ id: String) async throws -> BuildApp {
        let response: BuildSnapshot = try await read(path(id))
        return response.app
    }
    func submit(app: BuildApp?, prompt: String?, model: String?, effort: String?, key: String) async throws -> BuildApp {
        var body: [String: Any] = [:]
        if let app { body["mode"] = prompt == nil ? "preview" : "build"; body["revision"] = app.revision }
        if let prompt {
            body["prompt"] = prompt
            if let model, !model.isEmpty { body["model"] = model }
            if let effort, !effort.isEmpty { body["effort"] = effort }
        }
        let target = try app.map { try path($0.id) + "/turns" } ?? "apps"
        let response: BuildSnapshot = try await read(target, method: "POST", body: JSONSerialization.data(withJSONObject: body), key: key)
        return response.app
    }
    func watch(_ id: String, onApp: @MainActor (BuildApp) -> Void) async throws {
        let request = try makeRequest(path(id) + "/events", stream: true)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw BuildError.invalidProgress }
        guard (200..<300).contains(http.statusCode) else { throw BuildError.response(http.statusCode, "") }
        guard http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else { throw BuildError.invalidProgress }
        var parser = BuildEventParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let app = try parser.consume(line) {
                guard app.id == id, app.turns != nil else { throw BuildError.invalidProgress }
                await onApp(app)
                if !app.building { return }
            }
        }
    }
}
