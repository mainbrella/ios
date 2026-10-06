import SwiftUI

/// A short-lived foreground account subscription owned by the system share sheet.
@MainActor final class ShareStore: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published var selection: Workspace?
    @Published var instruction = ""
    @Published private(set) var payload: SharePayload?
    @Published private(set) var preparing = true
    @Published private(set) var loading = true
    @Published private(set) var hasLoaded = false
    @Published private(set) var liveState: LiveState = .connecting
    @Published private(set) var sending = false
    @Published private(set) var sent = false
    @Published private(set) var failure: String?
    @Published private(set) var syncError: String?
    let connected: Bool
    private let client: APIClient
    private let readToken: () -> String
    private let activity: ActivityStream
    private var snapshotPending = false
    private var snapshotTask: Task<Void, Never>?
    private var attempt: Attempt?

    private struct Attempt {
        let id: String
        let workspace: Workspace
        let message: InboxMessage
    }

    init(token: String = Keychain.read(), session: URLSession = .shared,
         readToken: @escaping () -> String = Keychain.read, activity: ActivityStream? = nil) {
        connected = !token.isEmpty
        client = APIClient(baseURL: ServiceURLs.api, token: token, session: session)
        self.readToken = readToken
        self.activity = activity ?? ActivityStream()
    }

    var canSend: Bool {
        connected && !preparing && payload != nil && !sending && !sent &&
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        selection.map { workspaces.contains($0) } == true
    }

    func prepare(_ providers: [NSItemProvider]) async {
        defer { preparing = false }
        do {
            let result = try await SharePayload.load(providers)
            try Task.checkCancellation()
            payload = result
        } catch {
            if !Task.isCancelled {
                failure = (error as? ShareFailure)?.localizedDescription ?? "This item couldn't be prepared. Close this sheet and share it again."
            }
        }
    }

    func followActivity() async {
        guard connected else { loading = false; return }
        await activity.run(client: client, state: { state in
            self.liveState = state
            if state == .unavailable || state == .authenticationRequired { self.scheduleSnapshot() }
        }, event: { frame in
            if frame.type == "ready" || (frame.type == "changed" && frame.resource == .containers) { self.scheduleSnapshot() }
        })
        if Task.isCancelled { stop() }
        else { await snapshotTask?.value }
    }

    func stop() {
        snapshotTask?.cancel(); snapshotTask = nil; snapshotPending = false
    }

    private func scheduleSnapshot() {
        snapshotPending = true
        guard snapshotTask == nil else { return }
        snapshotTask = Task {
            await loadWorkspaces()
            snapshotTask = nil
        }
    }

    func refresh() async {
        guard connected else { return }
        scheduleSnapshot()
        await snapshotTask?.value
    }

    private func loadWorkspaces() async {
        loading = true
        defer { loading = false }
        while snapshotPending && !Task.isCancelled {
            snapshotPending = false
            do {
                let spaces = try await client.workspaces().filter { $0.status == "running" }
                try Task.checkCancellation()
                let firstLoad = !hasLoaded
                workspaces = spaces
                // A replacement generation must be selected explicitly, never substituted.
                if let selection, !spaces.contains(selection) { self.selection = nil }
                if firstLoad, spaces.count == 1 { selection = spaces.first }
                hasLoaded = true; syncError = nil
            } catch {
                if !Task.isCancelled { syncError = error.localizedDescription }
            }
        }
    }

    func send() async {
        guard canSend, let workspace = selection, let payload else { return }
        sending = true; failure = nil
        defer { sending = false }
        do {
            guard readToken() == client.token else { throw ShareFailure.accountChanged }
            let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unchanged retries keep the same bytes and completion filename.
            if attempt?.workspace != workspace || attempt?.message.instruction != instruction {
                let id = UUID().uuidString.lowercased()
                attempt = Attempt(id: id, workspace: workspace, message: InboxMessage(version: 1,
                    createdAt: ISO8601DateFormatter().string(from: Date()), workspaceID: workspace.id,
                    generation: workspace.createdAt, source: "ios-share", instruction: instruction,
                    text: payload.text, attachment: payload.attachment == nil ? nil : "message-\(id).jpg"))
            }
            guard let attempt else { return }
            try await client.sendInbox(attempt.message, attachment: payload.attachment, id: attempt.id, workspace: attempt.workspace)
            sent = true
        } catch {
            failure = error.localizedDescription + " Your instruction is still here."
        }
    }
}
