import SwiftUI

/// A tab is a local view of a cloud workspace, not a new agent process.
@MainActor final class ConsoleTab: ObservableObject, Identifiable {
    let id = UUID()
    let workspace: Workspace
    @Published var draft = ""
    @Published var executionID: String?
    @Published var sending = false
    @Published var feedback: String?
    private var attempt: InboxAttempt?

    init(workspace: Workspace) { self.workspace = workspace }

    func send(using store: AppStore) async {
        guard !sending, store.workspaces.contains(where: {
            $0.id == workspace.id && $0.createdAt == workspace.createdAt && $0.status == "running"
        }) else { return }
        let instruction = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        let snapshot = InboxDraft(instruction: instruction, text: "", attachment: nil)
        if attempt?.draft != snapshot { attempt = InboxAttempt(draft: snapshot, workspace: workspace) }
        guard let attempt else { return }
        let revision = store.revision
        sending = true; feedback = nil
        defer { sending = false }
        do {
            try await store.api.sendInbox(attempt.message, attachment: nil, id: attempt.id, workspace: workspace)
            guard store.revision == revision else { return }
            draft = ""; self.attempt = nil
            feedback = "Saved to workspace inbox. An agent must read it to continue."
        } catch {
            guard store.revision == revision else { return }
            feedback = error.localizedDescription + " Your prompt is still here; retry when ready."
        }
    }
}

@MainActor final class ConsoleTabs: ObservableObject {
    @Published var tabs: [ConsoleTab] = []
    @Published var selectedID: UUID?
    var selected: ConsoleTab? { tabs.first { $0.id == selectedID } }
    func open(_ workspace: Workspace) {
        let tab = ConsoleTab(workspace: workspace)
        tabs.append(tab); selectedID = tab.id
    }
    func close(_ tab: ConsoleTab) {
        guard !tab.sending else { return }
        let index = tabs.firstIndex { $0.id == tab.id } ?? 0
        tabs.removeAll { $0.id == tab.id }
        if selectedID == tab.id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }
    func reset() { tabs = []; selectedID = nil }
}

struct ConsoleView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var console: ConsoleTabs
    @State private var choosingWorkspace = false
    @State private var closing: ConsoleTab?
    private func status(for tab: ConsoleTab) -> String {
        guard store.workspaces.contains(where: { $0.id == tab.workspace.id && $0.createdAt == tab.workspace.createdAt && $0.status == "running" }) else { return "Unavailable" }
        let jobs = store.jobs[tab.workspace.id, default: []]
        let review = jobs.filter(\.needsReview).count
        if review > 0 { return "\(review) need review" }
        let running = jobs.filter(\.running).count
        return running > 0 ? "\(running) running" : "Idle"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(console.tabs) { tab in
                                Button { console.selectedID = tab.id } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tab.workspace.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text("Tab \((console.tabs.firstIndex { $0.id == tab.id } ?? 0) + 1) · \(status(for: tab))")
                                            .font(.caption).foregroundStyle(Theme.muted)
                                    }.padding(.horizontal, 12).frame(minHeight: 52)
                                        .background(console.selectedID == tab.id ? Theme.surface : Color.clear, ignoresSafeAreaEdges: [])
                                }.buttonStyle(.plain)
                                    .accessibilityAddTraits(console.selectedID == tab.id ? .isSelected : [])
                                    .id(tab.id)
                                    .contextMenu { Button("Close tab", role: .destructive) { closing = tab }.disabled(tab.sending) }
                            }
                        }
                    }.scrollIndicators(.hidden)
                    .onChange(of: console.selectedID) { _, id in
                        if let id { reader.scrollTo(id, anchor: .center) }
                    }
                }
                Button { choosingWorkspace = true } label: {
                    Image(systemName: "plus").frame(width: 48, height: 52)
                }.accessibilityLabel("New workspace tab").accessibilityIdentifier("new-console-tab")
            }
            Divider()
            if let tab = console.selected {
                ConsolePane(tab: tab).id(tab.id)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Open a workspace to start.").font(.headline)
                    Text("Keep prompts, execution output, and previews close. Each tab has its own draft.").foregroundStyle(Theme.muted)
                    Button("Open workspace") { choosingWorkspace = true }.buttonStyle(ActionStyle())
                    Text("Cloud machines run Linux. Review web apps in Preview; ask your agent for Android renders. Xcode and iOS simulators require a Mac.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }.padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.background(Theme.background).navigationTitle("Workspace").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { LiveStatus() }
                ToolbarItem(placement: .topBarLeading) {
                    if let tab = console.selected {
                        Button { closing = tab } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Close current tab").disabled(tab.sending)
                    }
                }
            }
            .sheet(isPresented: $choosingWorkspace) {
                NavigationStack {
                    List {
                        if store.loading && !store.hasLoaded { ProgressView("Loading workspaces…") }
                        if let error = store.syncError { Text(error).foregroundStyle(.orange) }
                        if store.hasLoaded && store.workspaces.isEmpty { Text("No workspaces yet. Create one at mainbrella.com.").foregroundStyle(Theme.muted) }
                        ForEach(store.workspaces) { workspace in
                            Button { console.open(workspace); choosingWorkspace = false } label: {
                                HStack {
                                    Label(workspace.name, systemImage: "terminal")
                                    Spacer()
                                    Text(workspace.status.capitalized).font(.caption).foregroundStyle(Theme.muted)
                                }.frame(minHeight: 44)
                            }.disabled(workspace.status != "running")
                        }
                    }.navigationTitle("Open workspace").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { choosingWorkspace = false } } }
                        .refreshable { await store.refresh() }
                }.presentationDetents([.medium, .large])
            }
            .confirmationDialog("Close this tab?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
                if let tab = closing { Button("Close tab", role: .destructive) { console.close(tab); closing = nil } }
            } message: { Text("The draft will be discarded. Cloud work keeps running.") }
    }
}

private struct ConsolePane: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var tab: ConsoleTab
    @StateObject private var speech = PromptSpeech()
    @State private var voicePrefix = ""
    @State private var port = "3000"
    @State private var showPort = false
    @State private var attachments = false
    @FocusState private var editing: Bool
    private var jobs: [Execution] {
        guard store.workspaces.contains(where: { $0.id == tab.workspace.id && $0.createdAt == tab.workspace.createdAt }) else { return [] }
        return store.jobs[tab.workspace.id, default: []]
    }
    private var available: Bool {
        store.workspaces.contains { $0.id == tab.workspace.id && $0.createdAt == tab.workspace.createdAt && $0.status == "running" }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(available ? "Linux · \(jobs.filter(\.running).count) running" : "Workspace unavailable", systemImage: available ? "server.rack" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                Button { showPort = true } label: { Label("Preview", systemImage: "globe").frame(minHeight: 44) }
                    .font(.subheadline).disabled(!available || store.previewBusy)
            }.padding(.horizontal, 16)
            if let error = store.syncError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16) }
            if let explanation = store.liveState.explanation { Text(explanation).font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 16) }
            if !jobs.isEmpty {
                Picker("Execution", selection: $tab.executionID) {
                    Text("Choose execution").tag(String?.none)
                    ForEach(jobs) { job in Text("\(job.statusLabel) · \(job.id.prefix(8))").tag(Optional(job.id)) }
                }.pickerStyle(.menu).padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let job = jobs.first(where: { $0.id == tab.executionID }) {
                ExecutionView(workspace: tab.workspace, execution: job, embedded: true).id(job.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Execution output").font(.subheadline.weight(.semibold))
                        Text(jobs.isEmpty ? "No executions yet. Output appears here when work runs on this machine." : "Choose an execution to follow its output.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let feedback = tab.feedback { Text(feedback).font(.caption).foregroundStyle(Theme.muted).accessibilityIdentifier("console-feedback") }
                if let failure = speech.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                TextField("Prompt for this workspace", text: $tab.draft, axis: .vertical)
                    .lineLimit(2...5).focused($editing).padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Workspace prompt").disabled(tab.sending || speech.isRecording)
                HStack(spacing: 12) {
                    Button {
                        if speech.isRecording { speech.stop() }
                        else { editing = false; voicePrefix = tab.draft; Task { await speech.start() } }
                    } label: { Label(speech.isRecording ? "Stop" : "Dictate", systemImage: speech.isRecording ? "stop.circle.fill" : "mic").frame(minHeight: 44) }
                        .disabled(tab.sending || speech.isStarting || !available)
                    Button { attachments = true } label: { Image(systemName: "paperclip").frame(width: 44, height: 44) }
                        .accessibilityLabel("Send an attachment").disabled(tab.sending || speech.isRecording || !available)
                    Spacer()
                    Button { editing = false; Task { await tab.send(using: store) } } label: {
                        Label(tab.sending ? "Saving…" : "Send", systemImage: "arrow.up").frame(minHeight: 44)
                    }.buttonStyle(ActionStyle()).disabled(!available || tab.sending || speech.isStarting || speech.isRecording || tab.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Saves to /workspace/inbox for your agent to read.").font(.caption).foregroundStyle(Theme.muted)
            }.padding(16).frame(maxWidth: 800).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: speech.transcript) { _, value in
            if !value.isEmpty { tab.draft = voicePrefix + (voicePrefix.isEmpty ? "" : "\n") + value }
        }
        .onDisappear { speech.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { speech.stop() } }
        .onChange(of: available) { _, value in if !value { speech.stop() } }
        .onChange(of: jobs.map(\.id), initial: true) { _, ids in
            if tab.executionID == nil || !ids.contains(tab.executionID ?? "") { tab.executionID = jobs.first(where: \.running)?.id ?? jobs.first?.id }
        }
        .sheet(isPresented: $attachments) { NavigationStack { WorkspaceInboxView(workspace: tab.workspace, instruction: tab.draft) {
            tab.draft = ""
            tab.feedback = "Saved to workspace inbox. An agent must read it to continue."
        } }.environmentObject(store) }
        .alert("Open web preview", isPresented: $showPort) {
            TextField("Server port", text: $port).keyboardType(.numberPad)
            Button("Open") {
                guard let value = Int(port), (1024...65535).contains(value) else { store.error = "Enter a port between 1024 and 65535."; return }
                Task { await store.openPreview(tab.workspace, port: value) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Ask your agent to start the web server on this port, then open it here to review and annotate screenshots.") }
    }
}
