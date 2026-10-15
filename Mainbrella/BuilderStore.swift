import SwiftUI

enum BuilderPanel: String, CaseIterable { case build = "Build", preview = "Preview" }

struct BuilderSession: Identifiable {
    let id = UUID()
    var app: BuildApp?
    var draft = ""
    var model = ""
    var effort = ""
    var panel = BuilderPanel.build
    var sending = false
    var error: String?
    var hasUnseenUpdate = false
    var lastUsed = 0

    var title: String {
        if let name = app?.name, !name.isEmpty { return name }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? "New website" : String(prompt.prefix(80))
    }
    var subtitle: String { app?.prompt ?? "" }
    var isRunning: Bool { sending || app?.building == true }
    var needsAttention: Bool { error != nil || (!isRunning && app?.latestTurn?.status == "failed") }
    var status: String {
        if sending { return "Starting build…" }
        if app?.building == true { return "Building" }
        if needsAttention { return "Needs attention" }
        if app?.previewURL() != nil { return "Preview ready" }
        if (app?.revision ?? 0) > 0 { return "Saved" }
        return "Draft"
    }
}

@MainActor final class BuilderStore: ObservableObject {
    @Published private(set) var config: BuildConfig?
    @Published private(set) var apps: [BuildApp] = []
    @Published private(set) var sessions: [BuilderSession]
    @Published private(set) var activeSessionID: UUID
    @Published private(set) var loading = false
    @Published private(set) var following = false
    @Published private(set) var loadError: String?
    @Published private(set) var streamError: String?
    @Published private(set) var connectionNote: String?
    private var generation = UUID()
    private var streamRunID = UUID()
    private var restoredRunningSessions = false
    private var selectionSequence = 0
    private var attempts: [UUID: Attempt] = [:]
    private var previews: [UUID: BuilderPreviewState] = [:]
    private struct Attempt: Equatable {
        let appID: String?
        let revision: Int?
        let prompt: String?
        let model: String
        let effort: String
        var key = UUID().uuidString.lowercased()
        func matches(_ other: Attempt) -> Bool {
            appID == other.appID && revision == other.revision && prompt == other.prompt && model == other.model && effort == other.effort
        }
    }

    init() {
        let session = BuilderSession()
        sessions = [session]; activeSessionID = session.id
    }
    var activeSession: BuilderSession { sessions.first { $0.id == activeSessionID } ?? sessions[0] }
    var recentSessions: [BuilderSession] { sessions.sorted { $0.lastUsed > $1.lastUsed } }
    var selected: BuildApp? { activeSession.app }
    var draft: String {
        get { activeSession.draft }
        set { updateSession(activeSessionID) { $0.draft = newValue } }
    }
    var model: String {
        get { activeSession.model }
        set {
            guard newValue != model else { return }
            let defaultEffort = config?.models?.first { $0.id == newValue }?.defaultEffort ?? ""
            updateSession(activeSessionID) { $0.model = newValue; $0.effort = defaultEffort }
        }
    }
    var effort: String {
        get { activeSession.effort }
        set { updateSession(activeSessionID) { $0.effort = newValue } }
    }
    var panel: BuilderPanel {
        get { activeSession.panel }
        set { updateSession(activeSessionID) { $0.panel = newValue } }
    }
    var error: String? {
        get { activeSession.error }
        set { updateSession(activeSessionID) { $0.error = newValue } }
    }
    var sending: Bool { activeSession.sending }
    var busy: Bool { activeSession.isRunning }
    var chosenModel: BuildModel? { config?.models?.first { $0.id == model } }
    var canSend: Bool { canSend(in: activeSession) }

    private func canSend(in session: BuilderSession) -> Bool {
        let prompt = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingCreates = sessions.filter { $0.app == nil && $0.sending }.count
        return config?.available == true && !session.isRunning && !prompt.isEmpty && prompt.count <= 6000
            && (session.app != nil || apps.count + pendingCreates < (config?.maxApps ?? 50))
    }
    private func updateSession(_ id: UUID, _ update: (inout BuilderSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        update(&sessions[index])
    }
    func reset() {
        generation = UUID(); streamRunID = UUID()
        for state in previews.values { state.controller.stop() }
        previews = [:]; attempts = [:]; selectionSequence = 0
        let session = BuilderSession()
        sessions = [session]; activeSessionID = session.id
        config = nil; apps = []; loading = false; following = false
        loadError = nil; streamError = nil; connectionNote = nil; restoredRunningSessions = false
    }
    func load(_ client: BuildClient) async {
        guard !loading else { return }
        let generation = self.generation
        loading = true; loadError = nil
        defer { if generation == self.generation { loading = false } }
        do {
            async let configuration = client.config()
            async let websites = client.apps()
            let (config, apps) = try await (configuration, websites)
            guard generation == self.generation, !Task.isCancelled else { return }
            self.config = config
            for index in sessions.indices {
                let chosen = config.models?.first { $0.id == sessions[index].model }
                if sessions[index].model.isEmpty || (config.models != nil && chosen == nil) {
                    sessions[index].model = config.model
                    sessions[index].effort = config.models?.first { $0.id == config.model }?.defaultEffort ?? ""
                } else if let chosen, !chosen.efforts.contains(sessions[index].effort) {
                    sessions[index].effort = chosen.defaultEffort
                }
            }
            receiveApps(apps)
            restoreRunningSessions()
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }
    private func restoreRunningSessions() {
        guard !restoredRunningSessions else { return }
        restoredRunningSessions = true
        let running = apps.filter(\.building)
        guard !running.isEmpty else { return }
        let replaceBlank = sessions.count == 1 && selected == nil && draft.isEmpty && !sending
        if replaceBlank {
            sessions = running.map { makeSession(app: $0) }
        } else {
            for app in running where !sessions.contains(where: { $0.app?.id == app.id }) {
                sessions.append(makeSession(app: app))
            }
        }
        if replaceBlank, let first = sessions.first { selectSession(first.id) }
    }
    private func makeSession(app: BuildApp? = nil) -> BuilderSession {
        let model = sessions.first(where: { $0.id == activeSessionID })?.model ?? config?.model ?? ""
        let effort = sessions.first(where: { $0.id == activeSessionID })?.effort
            ?? config?.models?.first { $0.id == model }?.defaultEffort ?? ""
        return BuilderSession(app: app, model: model, effort: effort)
    }
    func selectModel() { effort = chosenModel?.defaultEffort ?? "" }
    func selectSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectionSequence += 1
        let sequence = selectionSequence
        updateSession(id) { $0.lastUsed = sequence; $0.hasUnseenUpdate = false }
        activeSessionID = id
    }
    func switchToPreviousSession() {
        if let previous = recentSessions.first(where: { $0.id != activeSessionID }) { selectSession(previous.id) }
    }
    func open(_ app: BuildApp) {
        if let existing = sessions.first(where: { $0.app?.id == app.id }) { selectSession(existing.id); return }
        let cached = apps.first { $0.id == app.id } ?? app
        let session = makeSession(app: cached)
        sessions.append(session); selectSession(session.id)
    }
    func newWebsite() {
        let session = makeSession()
        sessions.append(session); selectSession(session.id)
    }
    @discardableResult func closeSession(_ id: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }), !session.sending else { return false }
        previews.removeValue(forKey: id)?.controller.stop()
        attempts[id] = nil
        if sessions.count == 1 { newWebsite() }
        sessions.removeAll { $0.id == id }
        if activeSessionID == id, let next = recentSessions.first { selectSession(next.id) }
        return true
    }
    func previewState(for id: UUID) -> BuilderPreviewState {
        if let state = previews[id] { return state }
        let state = BuilderPreviewState()
        previews[id] = state
        return state
    }
    func loadSelected(_ client: BuildClient, sessionID: UUID) async {
        guard let id = sessions.first(where: { $0.id == sessionID })?.app?.id else { return }
        let generation = self.generation
        do {
            let app = try await client.app(id)
            guard generation == self.generation, !Task.isCancelled,
                  sessions.contains(where: { $0.id == sessionID && $0.app?.id == id }) else { return }
            if attempts[sessionID] == nil { updateSession(sessionID) { $0.error = nil } }
            receive(app)
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            updateSession(sessionID) { $0.error = error.localizedDescription }
        }
    }
    func send(_ client: BuildClient, restartPreview: Bool = false, sessionID: UUID? = nil) async {
        let id = sessionID ?? activeSessionID
        guard let session = sessions.first(where: { $0.id == id }), !session.isRunning, config?.available == true else { return }
        let prompt = restartPreview ? nil : session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !restartPreview && !canSend(in: session) { return }
        if restartPreview && (session.app?.revision ?? 0) < 1 { return }
        let snapshot = Attempt(appID: session.app?.id, revision: session.app?.revision, prompt: prompt, model: session.model, effort: session.effort)
        if attempts[id]?.matches(snapshot) != true { attempts[id] = snapshot }
        guard let attempt = attempts[id] else { return }
        let generation = self.generation
        updateSession(id) { $0.sending = true; $0.error = nil }
        defer { if generation == self.generation { updateSession(id) { $0.sending = false } } }
        do {
            let app = try await client.submit(app: session.app, prompt: prompt, model: attempt.model, effort: attempt.effort, key: attempt.key)
            guard generation == self.generation, !Task.isCancelled else { return }
            // A create can finish after the user has switched to another draft.
            // Attach its response only to the session that submitted the request.
            updateSession(id) {
                $0.app = app; $0.panel = .build
                if !restartPreview && $0.draft == session.draft { $0.draft = "" }
            }
            receive(app)
            attempts[id] = nil
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            updateSession(id) { $0.error = error.localizedDescription }
            // An unchanged retry retains this session's exact key and payload,
            // even after switching sessions. Writes are never retried automatically.
        }
    }
    private func merged(_ app: BuildApp, with previous: BuildApp?) -> BuildApp {
        guard let previous else { return app }
        if app.revision < previous.revision { return previous }
        if let incoming = app.updatedAt, let cached = previous.updatedAt, incoming < cached { return previous }
        return BuildApp(id: app.id, name: app.name, prompt: app.prompt, revision: app.revision,
                        activeTurnId: app.activeTurnId, preview: app.preview, turns: app.turns ?? previous.turns,
                        updatedAt: app.updatedAt ?? previous.updatedAt)
    }
    private func receiveApps(_ incoming: [BuildApp]) {
        let previous = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let incomingIDs = Set(incoming.map(\.id))
        // Inventory reads can race a create response. Keep open local work until
        // an app-specific read confirms it is unavailable.
        let retained = apps.filter { app in
            !incomingIDs.contains(app.id) && (app.building || sessions.contains { $0.app?.id == app.id })
        }
        apps = incoming.map { merged($0, with: previous[$0.id]) } + retained
        for app in apps { updateSessions(with: app) }
    }
    private func receive(_ app: BuildApp) {
        let app = merged(app, with: apps.first { $0.id == app.id })
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index] = app }
        else { apps.insert(app, at: 0) }
        updateSessions(with: app)
    }
    private func updateSessions(with app: BuildApp) {
        for index in sessions.indices where sessions[index].app?.id == app.id {
            let previous = sessions[index].app
            let completed = (previous?.building == true || previous?.latestTurn?.running == true)
                && !app.building && app.latestTurn?.running == false
            sessions[index].app = app
            if completed {
                sessions[index].hasUnseenUpdate = sessions[index].id != activeSessionID
                if app.latestTurn?.status == "succeeded", app.previewURL() != nil { sessions[index].panel = .preview }
            }
        }
    }
    func run(_ client: BuildClient) async {
        let generation = self.generation
        let runID = UUID(); streamRunID = runID
        await load(client)
        guard generation == self.generation, !Task.isCancelled else { return }
        var failures = 0
        streamError = nil
        defer { if streamRunID == runID { following = false } }
        while !Task.isCancelled, generation == self.generation, streamRunID == runID {
            do {
                try await client.watchAll { [weak self] event in
                    guard let self, generation == self.generation, self.streamRunID == runID, !Task.isCancelled else { return }
                    switch event {
                    case .apps(let apps): self.receiveApps(apps)
                    case .app(let app): self.receive(app)
                    }
                    self.following = true; self.connectionNote = nil; self.streamError = nil
                }
                failures = 0
                // Account streams end after 55 seconds. Selection never restarts
                // the stream, so rapid switching cannot exhaust stream starts.
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                guard generation == self.generation, streamRunID == runID, !Task.isCancelled else { return }
                following = false
                if case BuildError.response(let status, _) = error, [401, 403, 404].contains(status) {
                    streamError = error.localizedDescription; return
                }
                failures += 1
                connectionNote = "Connection lost. Reconnecting… Your builds continue in the cloud."
                let delay = (error as? BuildStreamRetry)?.delay ?? min(20, pow(2, Double(min(failures, 4))))
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }
}
