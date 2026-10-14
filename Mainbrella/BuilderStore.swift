import SwiftUI

@MainActor final class BuilderStore: ObservableObject {
    @Published private(set) var config: BuildConfig?
    @Published private(set) var apps: [BuildApp] = []
    @Published private(set) var selected: BuildApp?
    @Published var draft = ""
    @Published var model = ""
    @Published var effort = ""
    @Published private(set) var loading = false
    @Published private(set) var sending = false
    @Published private(set) var following = false
    @Published var error: String?
    @Published private(set) var connectionNote: String?
    private var generation = UUID()
    private var attempt: Attempt?
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
    var busy: Bool { sending || selected?.building == true || apps.contains(where: \.building) }
    var chosenModel: BuildModel? { config?.models?.first { $0.id == model } }
    var canSend: Bool {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return config?.available == true && !loading && !busy && !prompt.isEmpty && prompt.count <= 6000
            && (selected != nil || apps.count < (config?.maxApps ?? 50))
    }
    func reset() {
        generation = UUID(); config = nil; apps = []; selected = nil
        draft = ""; model = ""; effort = ""; loading = false; sending = false
        following = false; error = nil; connectionNote = nil; attempt = nil
    }
    func load(_ client: BuildClient) async {
        guard !loading else { return }
        let generation = self.generation
        loading = true; error = nil
        defer { if generation == self.generation { loading = false } }
        do {
            async let configuration = client.config()
            async let websites = client.apps()
            let (config, apps) = try await (configuration, websites)
            guard generation == self.generation, !Task.isCancelled else { return }
            self.config = config; self.apps = apps
            if model.isEmpty { model = config.model; selectModel() }
            // Restore an account's running build so leaving the app never loses it.
            if selected == nil, let running = apps.first(where: \.building) { selected = running }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    func selectModel() { effort = chosenModel?.defaultEffort ?? "" }
    func open(_ app: BuildApp) {
        guard !sending else { return }
        selected = app; draft = ""; attempt = nil; error = nil; connectionNote = nil
    }
    func newWebsite() {
        guard !sending else { return }
        selected = nil; draft = ""; attempt = nil; error = nil; connectionNote = nil
    }
    func send(_ client: BuildClient, restartPreview: Bool = false) async {
        guard !busy, config?.available == true else { return }
        let prompt = restartPreview ? nil : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !restartPreview && !canSend { return }
        if restartPreview && (selected?.revision ?? 0) < 1 { return }
        let snapshot = Attempt(appID: selected?.id, revision: selected?.revision, prompt: prompt, model: model, effort: effort)
        if attempt?.matches(snapshot) != true { attempt = snapshot }
        guard let attempt else { return }
        let generation = self.generation
        let submittedDraft = draft
        sending = true; error = nil
        defer { if generation == self.generation { sending = false } }
        do {
            let app = try await client.submit(app: selected, prompt: prompt, model: attempt.model, effort: attempt.effort, key: attempt.key)
            guard generation == self.generation, !Task.isCancelled else { return }
            receive(app)
            if !restartPreview && draft == submittedDraft { draft = "" }
            self.attempt = nil
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            // A lost response may already have queued work. An unchanged retry
            // uses the same key and payload; never retry a write automatically.
        }
    }
    private func receive(_ app: BuildApp) {
        selected = app
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index] = app }
        else { apps.insert(app, at: 0) }
    }
    func follow(_ client: BuildClient, id: String) async {
        let generation = self.generation
        var failures = 0
        defer { if generation == self.generation, selected?.id == id { following = false } }
        while !Task.isCancelled, generation == self.generation, selected?.id == id {
            do {
                let app = try await client.app(id)
                guard generation == self.generation, selected?.id == id, !Task.isCancelled else { return }
                receive(app)
                connectionNote = nil
                guard app.building else { return }
                following = true
                try await client.watch(id) { [weak self] snapshot in
                    guard let self, generation == self.generation, self.selected?.id == id, !Task.isCancelled else { return }
                    self.receive(snapshot); self.connectionNote = nil
                }
                failures = 0
                guard selected?.building == true else { return }
                // The backend intentionally ends streams after 55 seconds.
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                guard generation == self.generation, selected?.id == id, !Task.isCancelled else { return }
                following = false
                if case BuildError.response(let status, _) = error, [401, 403, 404].contains(status) {
                    self.error = error.localizedDescription; return
                }
                failures += 1
                connectionNote = "Connection lost. Reconnecting… Your build continues in the cloud."
                do { try await Task.sleep(for: .seconds(min(20, pow(2, Double(min(failures, 4)))))) }
                catch { return }
            }
        }
    }
}
