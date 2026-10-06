import Foundation
import Security

enum ServiceURLs {
    static let website = URL(string: "https://mainbrella.com/")!
    static let api = URL(string: "https://api.mainbrella.com/")!
    static let apiKeys = website.appendingPathComponent("api-keys/")
}

enum APIError: LocalizedError {
    case response(Int, String)
    case invalidURL
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The server returned an invalid preview link. Refresh previews and try again."
        case .response(let status, let code):
            if status == 401 { return "Your API key is invalid or expired. Update it in Account." }
            if status == 402 { return "An active plan is required. Manage your plan at mainbrella.com." }
            if code == "preview_reconciliation_required" { return "Preview cleanup is required. Inspect and revoke the outstanding grant before creating another." }
            if code == "execution_not_found" { return "This execution is no longer available. Execution history expires after one hour." }
            if code == "container_not_running" { return "This workspace has stopped or been replaced. Refresh your projects to continue." }
            if status == 413 { return "This attachment is too large. Choose a smaller image or shorten the message." }
            return "The request could not be completed (\(status)). Please refresh and try again."
        }
    }
}

struct APIClient {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    func request(_ path: String, method: String = "GET", workspace: Workspace? = nil,
                 query: [URLQueryItem] = [], body: Data? = nil, contentType: String = "application/json", idempotencyKey: String? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = (workspace.map { [URLQueryItem(name: "id", value: $0.id), URLQueryItem(name: "createdAt", value: $0.createdAt)] } ?? []) + query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        request.httpBody = body
        request.timeoutInterval = 35
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.response(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? ""
            throw APIError.response(http.statusCode, code)
        }
        return data
    }
    private struct Failure: Decodable { let error: String }
    func workspaces() async throws -> [Workspace] {
        struct Response: Decodable { let containers: [Workspace] }
        return try JSONDecoder().decode(Response.self, from: await request("containers")).containers
    }
    func executions(_ workspace: Workspace) async throws -> [Execution] {
        struct Response: Decodable { let executions: [Execution] }
        return try JSONDecoder().decode(Response.self, from: await request("containers/executions", workspace: workspace)).executions
    }
    func execution(_ id: String, workspace: Workspace) async throws -> ExecutionDetail {
        try JSONDecoder().decode(ExecutionDetail.self, from: await request("containers/executions/\(id)", workspace: workspace))
    }
    func sendInbox(_ message: InboxMessage, attachment: Data?, id: String, workspace: Workspace) async throws {
        let metadata = try JSONEncoder().encode(message)
        guard metadata.count <= 1_048_576, (attachment?.count ?? 0) <= 1_048_576 else {
            throw APIError.response(413, "file_too_large")
        }
        try await makeInbox(workspace)
        if let attachment, let filename = message.attachment {
            try await upload(attachment, path: "/workspace/inbox/\(filename)", workspace: workspace)
        }
        // The JSON file commits the handoff after its attachment is available.
        try await upload(metadata, path: "/workspace/inbox/message-\(id).json", workspace: workspace)
    }
    func previews(_ workspace: Workspace) async throws -> [PreviewGrant] {
        struct Response: Decodable { let previews: [PreviewGrant] }
        return try JSONDecoder().decode(Response.self, from: await request("containers/previews", workspace: workspace)).previews
    }
    func createPreview(_ workspace: Workspace, port: Int) async throws -> PreviewGrant {
        let data = try JSONSerialization.data(withJSONObject: ["port": port, "ttlSeconds": 900])
        return try JSONDecoder().decode(PreviewGrant.self, from: await request("containers/previews", method: "POST", workspace: workspace, body: data))
    }
    func revokePreview(_ workspace: Workspace, id: String) async throws {
        _ = try await request("containers/previews", method: "DELETE", workspace: workspace, query: [.init(name: "previewId", value: id)])
    }
    func upload(_ data: Data, path: String, workspace: Workspace) async throws {
        guard data.count <= 1_048_576 else { throw APIError.response(413, "file_too_large") }
        _ = try await request("containers/files", method: "PUT", workspace: workspace, query: [.init(name: "path", value: path)], body: data, contentType: "application/octet-stream")
    }
    func makeInbox(_ workspace: Workspace) async throws {
        _ = try await request("containers/files/mkdir", method: "POST", workspace: workspace,
                              body: JSONSerialization.data(withJSONObject: ["path": "/workspace/inbox", "recursive": true]))
    }
}

enum Keychain {
    static let service = "com.mainbrella.ios"
    static func read() -> String {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "api-key", kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let status = updated == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : updated
        guard status == errSecSuccess else { throw APIError.response(0, "keychain") }
    }
}
