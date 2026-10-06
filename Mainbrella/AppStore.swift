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
    @Published private(set) var revision = 0
    @Published private(set) var liveState: LiveState = .paused
    @Published private(set) var executionVersions: [String: Int] = [:]
    private let activity: ActivityStream
    private var liveRunID = UUID()
    private var liveTask: Task<Void, Never>?
    private var fullSnapshotPending = false
    private var changes: [String: Set<ActivityFrame.Resource>] = [:]
    private var syncTask: Task<Void, Never>?

    init(token: String = Keychain.read(), session: URLSession = .shared,
         saveToken: @escaping (String) throws -> Void = Keychain.save,
         activity: ActivityStream? = nil) {
        self.token = token
        self.session = session
        self.saveToken = saveToken
        self.activity = activity ?? ActivityStream()
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
            resetLiveSession()
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
            resetLiveSession()
            revision += 1
            token = ""
            workspaces = []; jobs = [:]; grants = [:]; preview = nil
            error = nil; syncError = nil; hasLoaded = false
        } catch { self.error = error.localizedDescription }
    }
    private func resetLiveSession() {
        liveRunID = UUID()
        liveTask?.cancel(); liveTask = nil
        syncTask?.cancel(); syncTask = nil
        fullSnapshotPending = false; changes = [:]; executionVersions = [:]
        liveState = .paused
    }
    func followActivity() async {
        guard connected else { return }
        liveTask?.cancel()
        let runID = UUID()
        liveRunID = runID
        let revision = self.revision
        defer {
            if liveRunID == runID {
                liveTask = nil
                if Task.isCancelled { liveState = .paused }
            }
        }
        do {
            let client = try api
            let task = Task {
                await activity.run(client: client, state: { state in
                    guard revision == self.revision, runID == self.liveRunID else { return }
                    self.liveState = state
                    if state == .unavailable || state == .authenticationRequired { self.scheduleSnapshot() }
                }, event: { frame in
                    guard revision == self.revision, runID == self.liveRunID else { return }
                    self.receiveActivity(frame)
                })
            }
            liveTask = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        } catch { if revision == self.revision { syncError = error.localizedDescription } }
    }
    func receiveActivity(_ frame: ActivityFrame) {
        guard connected else { return }
        if frame.type == "ready" || frame.resource == .containers {
            scheduleSnapshot()
            return
        }
        guard frame.type == "changed", let resource = frame.resource,
              let id = frame.containerId, let generation = frame.createdAt else { return }
        guard let workspace = workspaces.first(where: { $0.id == id }) else {
            scheduleSnapshot(); return
        }
        // Hints can arrive after a workspace was replaced. Never mix generations.
        guard workspace.createdAt == generation else { return }
        changes[id, default: []].insert(resource)
        scheduleSync()
    }
    private func scheduleSnapshot() {
        fullSnapshotPending = true
        scheduleSync()
    }
    private func scheduleSync() {
        guard syncTask == nil else { return }
        let revision = self.revision
        syncTask = Task {
            await synchronize()
            if revision == self.revision { syncTask = nil }
        }
    }
    func refresh() async {
        guard connected else { return }
        scheduleSnapshot()
        await syncTask?.value
    }
    private func synchronize() async {
        guard connected, !loading else { return }
        loading = true
        let revision = self.revision
        defer { loading = false }
        // Keep invalidations received during an HTTP read; drain them afterward.
        while fullSnapshotPending || !changes.isEmpty {
            guard revision == self.revision, !Task.isCancelled else { return }
            let full = fullSnapshotPending
            let pending = changes
            let previewAtStart = preview?.id
            fullSnapshotPending = false; changes = [:]
            do {
                let client = try api
                let spaces = full ? try await client.workspaces() : workspaces
                var nextJobs = full ? [:] : jobs
                var nextGrants = full ? [:] : grants
                var refreshedExecutions: [String] = []
                var refreshedPreviews: Set<String> = []
                var failures = 0
                for space in spaces {
                    let resources = full ? Set([ActivityFrame.Resource.executions, .previews]) : pending[space.id, default: []]
                    let sameGeneration = workspaces.contains { $0.id == space.id && $0.createdAt == space.createdAt }
                    async let executions = Self.result { resources.contains(.executions) ? try await client.executions(space) : nil }
                    async let previews = Self.result { resources.contains(.previews) ? try await client.previews(space) : nil }
                    switch await executions {
                    case .success(let values):
                        if let values { nextJobs[space.id] = values; refreshedExecutions.append(space.id) }
                    case .failure:
                        failures += 1; nextJobs[space.id] = sameGeneration ? jobs[space.id] : nil
                    }
                    switch await previews {
                    case .success(let values):
                        if let values { nextGrants[space.id] = values; refreshedPreviews.insert(space.id) }
                    case .failure:
                        failures += 1; nextGrants[space.id] = sameGeneration ? grants[space.id] : nil
                    }
                }
                guard revision == self.revision, !Task.isCancelled else { return }
                workspaces = spaces; jobs = nextJobs; grants = nextGrants
                for id in refreshedExecutions { executionVersions[id, default: 0] += 1 }
                if full || failures > 0 {
                    syncError = failures == 0 ? nil : "Some activity or preview details couldn't load. Pull to refresh to try again."
                }
                hasLoaded = true
                if let preview {
                    let workspaceAvailable = spaces.contains { $0.id == preview.workspace.id && $0.createdAt == preview.workspace.createdAt && $0.status == "running" }
                    let grantRevoked = preview.id == previewAtStart && refreshedPreviews.contains(preview.workspace.id) && !nextGrants[preview.workspace.id, default: []].contains { $0.id == preview.grantID }
                    if !workspaceAvailable || grantRevoked || preview.expiresAt <= Date() { self.preview = nil }
                }
            } catch {
                guard revision == self.revision, !Task.isCancelled else { return }
                syncError = error.localizedDescription
            }
        }
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
