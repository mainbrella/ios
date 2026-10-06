import SwiftUI

@MainActor final class AppStore: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var jobs: [String: [Execution]] = [:]
    @Published private(set) var grants: [String: [PreviewGrant]] = [:]
    @Published private(set) var loading = false
    @Published private(set) var hasLoaded = false
    @Published var error: String?
    @Published var syncError: String?
    @Published var preview: PreviewSession?
    @Published private(set) var previewBusy = false
    @Published private var token: String
    private let session: URLSession
    private let saveToken: (String) throws -> Void
    private var revision = 0

    init(token: String = Keychain.read(), session: URLSession = .shared,
         saveToken: @escaping (String) throws -> Void = Keychain.save) {
        self.token = token
        self.session = session
        self.saveToken = saveToken
    }
    var connected: Bool { !token.isEmpty }
    var api: APIClient {
        get throws {
            guard connected else { throw APIError.response(401, "") }
            return APIClient(baseURL: ServiceURLs.api, token: token, session: session)
        }
    }
    func connect(token: String) async -> Bool {
        guard !loading else { return false }
        loading = true
        defer { loading = false }
        do {
            let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw APIError.response(401, "") }
            let client = APIClient(baseURL: ServiceURLs.api, token: key, session: session)
            let spaces = try await client.workspaces()
            try saveToken(key)
            revision += 1
            self.token = key
            preview = nil
            workspaces = spaces
            jobs = [:]; grants = [:]; error = nil; syncError = nil; hasLoaded = false
            loading = false
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func disconnect() {
        guard !loading, !previewBusy else { return }
        do {
            try saveToken("")
            revision += 1
            token = ""
            workspaces = []; jobs = [:]; grants = [:]; preview = nil
            error = nil; syncError = nil; hasLoaded = false
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard connected, !loading else { return }
        loading = true
        let revision = self.revision
        defer { loading = false }
        do {
            let client = try api
            let spaces = try await client.workspaces()
            var nextJobs: [String: [Execution]] = [:]
            var nextGrants: [String: [PreviewGrant]] = [:]
            var failures = 0
            for space in spaces {
                let sameGeneration = workspaces.contains { $0.id == space.id && $0.createdAt == space.createdAt }
                async let executions = Self.result { try await client.executions(space) }
                async let previews = Self.result { try await client.previews(space) }
                switch await executions {
                case .success(let values): nextJobs[space.id] = values
                case .failure: failures += 1; nextJobs[space.id] = sameGeneration ? jobs[space.id] : nil
                }
                switch await previews {
                case .success(let values): nextGrants[space.id] = values
                case .failure: failures += 1; nextGrants[space.id] = sameGeneration ? grants[space.id] : nil
                }
            }
            guard revision == self.revision else { return }
            workspaces = spaces; jobs = nextJobs; grants = nextGrants
            syncError = failures == 0 ? nil : "Some activity or preview details couldn't load. Pull to refresh to try again."
            hasLoaded = true
            if let preview, !spaces.contains(where: { $0.id == preview.workspace.id && $0.createdAt == preview.workspace.createdAt }) {
                self.preview = nil
            }
        } catch { if revision == self.revision { self.syncError = error.localizedDescription } }
    }
    private nonisolated static func result<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
    func openPreview(_ workspace: Workspace, port: Int = 3000) async {
        guard connected, !previewBusy, workspace.status == "running" else { return }
        previewBusy = true
        let revision = self.revision
        defer { previewBusy = false }
        do {
            let grant = try await api.createPreview(workspace, port: port)
            guard revision == self.revision else { return }
            guard let url = grant.url, url.scheme == "https" else { throw APIError.invalidURL }
            preview = PreviewSession(grantID: grant.id, workspace: workspace, url: url, expiresAt: Date(timeIntervalSince1970: grant.expiresAt / 1000))
            grants[workspace.id, default: []].append(grant)
        } catch { if revision == self.revision { self.error = error.localizedDescription } }
    }
    func revoke(_ workspace: Workspace, grant: PreviewGrant) async {
        let revision = self.revision
        do {
            try await api.revokePreview(workspace, id: grant.id)
            guard revision == self.revision else { return }
            grants[workspace.id]?.removeAll { $0.id == grant.id }
            if preview?.workspace.id == workspace.id && preview?.grantID == grant.id { preview = nil }
        } catch { if revision == self.revision { self.error = error.localizedDescription } }
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
