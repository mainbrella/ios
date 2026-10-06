import SwiftUI
import LocalAuthentication

@MainActor final class AppStore: ObservableObject {
    @Published var demo = true
    @Published var workspaces: [Workspace] = [.demo]
    @Published var jobs: [String: [Execution]] = [:]
    @Published var grants: [String: [PreviewGrant]] = [:]
    @Published var approvals = Approval.examples
    @Published var loading = false
    @Published var error: String?
    @Published var syncError: String?
    @Published var notice: String?
    @Published var preview: PreviewSession?
    @Published var previewBusy = false
    @Published var endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? "https://api.mainbrella.com"
    private var token = Keychain.read()
    private var revision = 0
    init() {
        if !token.isEmpty { demo = false; workspaces = []; approvals = [] }
    }
    var connected: Bool { !token.isEmpty }
    var api: APIClient {
        get throws {
            guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw APIError.invalidURL }
            return APIClient(baseURL: url, token: token)
        }
    }
    func connect(endpoint: String, token: String) async -> Bool {
        guard !loading else { return false }
        let oldEndpoint = self.endpoint
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try api
            let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw APIError.response(401, "") }
            let client = APIClient(baseURL: try api.baseURL, token: key)
            loading = true
            defer { loading = false }
            let spaces = try await client.workspaces()
            try Keychain.save(key)
            self.token = key
            UserDefaults.standard.set(self.endpoint, forKey: "endpoint")
            demo = false
            preview = nil
            workspaces = spaces
            approvals = []
            jobs = [:]; grants = [:]; error = nil
            loading = false
            await refresh()
            return true
        } catch { self.endpoint = oldEndpoint; self.error = error.localizedDescription; return false }
    }
    func useDemo() {
        revision += 1
        demo = true; workspaces = [.demo]; jobs = [:]; grants = [:]
        approvals = Approval.examples; error = nil; syncError = nil; notice = nil; preview = nil
    }
    func disconnect() {
        do { try Keychain.save(""); token = ""; useDemo() }
        catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard !demo, !loading else { return }
        loading = true
        let revision = self.revision
        defer { loading = false }
        do {
            let client = try api
            let spaces = try await client.workspaces()
            var nextJobs: [String: [Execution]] = [:]
            var nextGrants: [String: [PreviewGrant]] = [:]
            for space in spaces {
                async let executions = client.executions(space)
                async let previews = client.previews(space)
                nextJobs[space.id] = try await executions
                nextGrants[space.id] = try await previews
            }
            guard revision == self.revision else { return }
            workspaces = spaces; jobs = nextJobs; grants = nextGrants; syncError = nil
        } catch { if revision == self.revision { self.syncError = error.localizedDescription } }
    }
    func decide(_ approval: Approval, approve: Bool) async {
        guard demo else { return }
        if approve && approval.sensitive {
            let context = LAContext()
            do { guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Approve use of the test secret in this demo") else { return } }
            catch { self.error = "Approval was not authenticated."; return }
        }
        withAnimation { approvals.removeAll { $0.id == approval.id } }
        notice = approve ? "Demo approval accepted." : "Demo request denied."
    }
    func openPreview(_ workspace: Workspace, port: Int = 3000) async {
        guard !previewBusy else { return }
        if demo { preview = PreviewSession(workspace: workspace, url: nil, expiresAt: nil); return }
        previewBusy = true
        defer { previewBusy = false }
        do {
            let grant = try await api.createPreview(workspace, port: port)
            guard let url = grant.url, url.scheme == "https" else { throw APIError.invalidURL }
            preview = PreviewSession(workspace: workspace, url: url, expiresAt: Date(timeIntervalSince1970: grant.expiresAt / 1000))
            grants[workspace.id, default: []].append(grant)
        } catch { self.error = error.localizedDescription }
    }
    func revoke(_ workspace: Workspace, grant: PreviewGrant) async {
        do {
            try await api.revokePreview(workspace, id: grant.id)
            grants[workspace.id]?.removeAll { $0.id == grant.id }
            if preview?.workspace.id == workspace.id { preview = nil }
        } catch { self.error = error.localizedDescription }
    }
}

@main struct MainbrellaApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).preferredColorScheme(.dark).tint(Theme.blue)
        }
    }
}
