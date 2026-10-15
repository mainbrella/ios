import SwiftUI

struct BuilderView: View {
    @EnvironmentObject private var account: AppStore
    @EnvironmentObject private var builder: BuilderStore
    @EnvironmentObject private var credits: ComputeCreditStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var speech = PromptSpeech()
    @State private var speechPrefix = ""
    @State private var speechSessionID: UUID?
    @State private var showingWebsites = false
    @State private var showingAccount = false
    @State private var showingSessions = false
    @State private var pendingCloseSession: BuilderSession?
    @State private var reconnect = UUID()
    @ScaledMetric(relativeTo: .body) private var composerHeight = 80
    @FocusState private var promptFocused: Bool
    private struct WatchIdentity: Equatable {
        let accountRevision: Int
        let active: Bool
        let reconnect: UUID
    }
    private struct SelectionIdentity: Equatable {
        let sessionID: UUID
        let active: Bool
        let reconnect: UUID
    }

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= 900
            VStack(spacing: 0) {
                if !sideBySide, builder.selected != nil {
                    Picker("Build view", selection: $builder.panel) {
                        Text("Build").tag(BuilderPanel.build)
                        Text("Preview").tag(BuilderPanel.preview)
                    }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
                        .accessibilityIdentifier("builder-panels")
                }
                if sideBySide, builder.selected != nil {
                    HStack(spacing: 0) {
                        conversation.id(builder.activeSessionID).frame(width: min(420, geometry.size.width * 0.42))
                        Divider()
                        preview.frame(maxWidth: .infinity)
                    }
                } else if builder.panel == .preview, builder.selected != nil {
                    preview
                } else { conversation.id(builder.activeSessionID) }
            }
        }
        .background(Theme.background)
        .navigationTitle(builder.selected?.name ?? "Mainbrella")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { stopSpeech(); showingWebsites = true } label: { Image(systemName: "folder").frame(width: 44, height: 44) }
                    .accessibilityLabel("Saved websites").accessibilityIdentifier("builder-websites")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { stopSpeech(); showingAccount = true } label: {
                    Image(systemName: "person.crop.circle").frame(width: 44, height: 44)
                }.accessibilityLabel("Account").accessibilityIdentifier("builder-account")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { sessionBar }
        .sheet(isPresented: $showingWebsites) { websites }
        .sheet(isPresented: $showingSessions) { sessions }
        .sheet(isPresented: $showingAccount) {
            NavigationStack {
                AccountView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showingAccount = false } }
                }
            }
        }
        .task(id: WatchIdentity(accountRevision: account.revision, active: scenePhase == .active, reconnect: reconnect)) {
            guard scenePhase == .active else { return }
            do { await builder.run(try account.buildAPI) }
            catch { builder.error = error.localizedDescription }
        }
        .task(id: SelectionIdentity(sessionID: builder.activeSessionID, active: scenePhase == .active, reconnect: reconnect)) {
            guard scenePhase == .active else { return }
            let sessionID = builder.activeSessionID
            do { await builder.loadSelected(try account.buildAPI, sessionID: sessionID) }
            catch { builder.error = error.localizedDescription }
        }
        .onChange(of: speech.transcript) { _, text in
            guard !text.isEmpty, speechSessionID == builder.activeSessionID else { return }
            builder.draft = speechPrefix + (speechPrefix.isEmpty ? "" : " ") + text
        }
        .onChange(of: builder.sending) { _, sending in if sending { stopSpeech() } }
        .onChange(of: builder.activeSessionID) { _, _ in
            stopSpeech(); promptFocused = false
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stopSpeech() } }
        .onDisappear { stopSpeech() }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let app = builder.selected {
                        if app.turns == nil { ProgressView("Loading build…") }
                        ForEach(app.turns ?? []) { turn in
                            turnView(turn)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("What would you like to build?").font(.title2.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            Text("Describe a website, then preview it and ask for changes.")
                                .font(.body).foregroundStyle(Theme.muted)
                        }
                        composer
                        ComputeCreditView()
                    }
                    if builder.loading { ProgressView("Loading websites…") }
                    if let note = builder.connectionNote {
                        Label(note, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(Theme.muted)
                    }
                    if let error = builder.error ?? builder.loadError ?? builder.streamError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
                            Button("Reconnect") { reconnect = UUID() }.frame(minHeight: 44)
                        }.accessibilityIdentifier("builder-error")
                    }
                    if builder.config?.available == false {
                        Text("Build is temporarily unavailable. Your saved websites are still here.").font(.subheadline).foregroundStyle(Theme.muted)
                    }
                }.padding(20).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(builder.selected == nil ? .top : .bottom)
            .scrollDismissesKeyboard(.interactively)
            if builder.selected != nil {
                composer.frame(maxWidth: .infinity).background(Theme.surface)
            }
        }
    }

    private func turnView(_ turn: BuildTurn) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if turn.mode == "build" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You").font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
                    Text(turn.prompt).font(.body).textSelection(.enabled)
                }
            }
            HStack(spacing: 10) {
                if turn.running { ProgressView().controlSize(.small) }
                else { Image(systemName: turn.status == "succeeded" ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(turn.status == "succeeded" ? Theme.green : .orange) }
                Text(turn.running ? (turn.stage.isEmpty ? "Building…" : turn.stage) : turn.status == "succeeded" ? "Preview ready" : "Build needs attention")
                    .font(.subheadline.weight(.semibold))
            }.accessibilityIdentifier("build-status-\(turn.id)")
            ForEach(turn.activity ?? []) { item in
                if item.type == "message" {
                    Text(item.text).font(.body).textSelection(.enabled).accessibilityIdentifier("build-message-\(item.id)")
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: activitySymbol(item.status)).foregroundStyle(item.status == "succeeded" ? Theme.green : Theme.muted)
                            .frame(width: 18).accessibilityLabel(item.status.capitalized)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text).font(.subheadline)
                            if let explanation = item.explanation, !explanation.isEmpty {
                                Text(explanation).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
            if let summary = turn.summary, !summary.isEmpty,
               !(turn.activity ?? []).contains(where: { $0.type == "message" && $0.text == summary }) {
                Text(summary).font(.body).textSelection(.enabled)
            }
            if turn.status == "failed" {
                Text(turn.errorExplanation ?? BuildError.response(0, turn.error ?? "build_failed").localizedDescription)
                    .font(.subheadline).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activitySymbol(_ status: String) -> String {
        switch status {
        case "succeeded": return "checkmark"
        case "failed", "blocked", "unknown": return "exclamationmark.circle"
        case "skipped": return "minus"
        default: return "ellipsis"
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = speech.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            if builder.draft.count > 6000 {
                Text("Prompts can contain up to 6,000 characters.").font(.caption).foregroundStyle(.orange)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $builder.draft)
                    .scrollContentBackground(.hidden).font(.body).focused($promptFocused)
                    .frame(height: min(composerHeight, 160))
                    .accessibilityLabel("Website prompt").accessibilityIdentifier("builder-prompt")
                    .disabled(builder.sending)
                if builder.draft.isEmpty {
                    Text(builder.selected == nil ? "Describe your website…" : "Ask for a change…")
                        .foregroundStyle(Theme.muted).padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            HStack(spacing: 8) {
                modelMenu
                Spacer(minLength: 0)
                Button {
                    if speech.isRecording || speech.isStarting { stopSpeech() }
                    else {
                        speechSessionID = builder.activeSessionID
                        speechPrefix = builder.draft
                        Task { await speech.start() }
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.circle" : "mic").font(.title3).frame(width: 44, height: 44)
                }.disabled(builder.sending).accessibilityLabel(speech.isRecording ? "Stop dictation" : "Dictate prompt")
                Button {
                    stopSpeech(); promptFocused = false
                    let sessionID = builder.activeSessionID
                    Task { do { await builder.send(try account.buildAPI, sessionID: sessionID) } catch { builder.error = error.localizedDescription } }
                } label: {
                    HStack(spacing: 6) {
                        if builder.sending { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.up") }
                        Text(builder.selected == nil ? "Build website" : "Send")
                    }.font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44)
                        .foregroundStyle(.white).background(builder.canSend ? Theme.actionBlue : Theme.surface, in: Capsule())
                }.disabled(!builder.canSend).accessibilityIdentifier("builder-submit")
            }
        }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 640)
    }

    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: $builder.model) {
                ForEach(builder.config?.models ?? []) { Text($0.name).tag($0.id) }
            }
            if let model = builder.chosenModel, model.efforts.count > 1 {
                Picker("Effort", selection: $builder.effort) {
                    ForEach(model.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(builder.chosenModel?.name ?? "Default model").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.caption).foregroundStyle(Theme.muted).frame(minHeight: 44)
        }.disabled(builder.sending || builder.config?.models?.isEmpty != false)
            .accessibilityLabel("Build model and effort")
    }

    private var preview: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if let app = builder.selected, let url = app.previewURL(at: context.date) {
                    BuilderPreviewView(url: url, revision: app.revision, state: builder.previewState(for: builder.activeSessionID))
                } else {
                    VStack(spacing: 12) {
                        if builder.selected?.building == true {
                            ProgressView()
                            Text("Your preview will appear when the build is ready.")
                        } else if (builder.selected?.revision ?? 0) > 0 {
                            Text("The preview has expired. Your website is saved.")
                            Button("Start preview") {
                                let sessionID = builder.activeSessionID
                                Task { do { await builder.send(try account.buildAPI, restartPreview: true, sessionID: sessionID) } catch { builder.error = error.localizedDescription } }
                                builder.panel = .build
                            }.buttonStyle(ActionStyle()).disabled(builder.busy || builder.config?.available != true)
                        } else { Text("Your preview will appear after a successful build.") }
                    }.font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.id(builder.activeSessionID)
        }
    }

    private var sessionBar: some View {
        HStack(spacing: 10) {
            Button {
                stopSpeech(); promptFocused = false; showingSessions = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.on.square")
                    Text("Sessions")
                    Text("\(builder.sessions.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    if unseenSessionCount > 0 {
                        Circle().fill(Theme.blue).frame(width: 7, height: 7)
                    }
                }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }
            .accessibilityLabel("Sessions")
            .accessibilityValue("\(builder.sessions.count) sessions, \(runningSessionCount) building, \(unseenSessionCount) with updates")
            .accessibilityIdentifier("builder-sessions")
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .contextMenu {
                if builder.sessions.count > 1 {
                    Button("Previous session", systemImage: "arrow.uturn.backward") {
                        stopSpeech(); promptFocused = false; builder.switchToPreviousSession()
                    }
                }
            }
            if runningSessionCount > 0, !dynamicTypeSize.isAccessibilitySize {
                Text("\(runningSessionCount) building")
                    .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                stopSpeech(); promptFocused = false; builder.newWebsite(); builder.panel = .build
            } label: {
                Image(systemName: "plus").font(.body.weight(.medium))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .foregroundStyle(Theme.blue)
            .accessibilityLabel("New website")
            .accessibilityIdentifier("builder-new-website")
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.muted.opacity(0.16)).frame(height: 0.5) }
    }

    private var runningSessionCount: Int { builder.sessions.filter(\.isRunning).count }
    private var unseenSessionCount: Int { builder.sessions.filter(\.hasUnseenUpdate).count }

    private var sessions: some View {
        NavigationStack {
            List {
                ForEach(builder.recentSessions) { session in
                    HStack(spacing: 8) {
                        Button {
                            stopSpeech(); promptFocused = false
                            builder.selectSession(session.id); showingSessions = false
                        } label: {
                            sessionRow(session).contentShape(Rectangle())
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("session-\(session.id.uuidString)")
                        .accessibilityAddTraits(builder.activeSessionID == session.id ? .isSelected : [])

                        Button { requestClose(session) } label: {
                            Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(session.sending)
                        .accessibilityLabel("Close \(session.title)")
                        .accessibilityIdentifier("close-session-\(session.id.uuidString)")
                    }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .overlay {
                if builder.sessions.isEmpty {
                    Text("No sessions yet.").font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSessions = false } } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 7) {
                    Text("Closing a session keeps its website and build.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    Button {
                        stopSpeech(); promptFocused = false; builder.newWebsite(); builder.panel = .build
                        showingSessions = false
                    } label: {
                        Label("New website", systemImage: "plus")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(.white).background(Theme.actionBlue, in: Capsule())
                    }.accessibilityIdentifier("session-new-website")
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8).background(.bar)
            }
            .confirmationDialog(
                "Close this session and discard its draft?",
                isPresented: Binding(get: { pendingCloseSession != nil }, set: { if !$0 { pendingCloseSession = nil } }),
                presenting: pendingCloseSession
            ) { session in
                Button("Close Session", role: .destructive) { closeSession(session) }
                Button("Cancel", role: .cancel) { pendingCloseSession = nil }
            } message: { _ in Text("Closing a session keeps its website and any submitted build.") }
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func sessionRow(_ session: BuilderSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(session.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                if builder.activeSessionID == session.id {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.blue)
                        .accessibilityLabel("Current session")
                }
                if session.hasUnseenUpdate {
                    Circle().fill(Theme.blue).frame(width: 7, height: 7).accessibilityLabel("Unseen update")
                }
                Spacer(minLength: 0)
            }
            if !session.subtitle.isEmpty {
                Text(session.subtitle).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2)
            }
            HStack(spacing: 6) {
                if session.isRunning { ProgressView().controlSize(.mini) }
                else if session.needsAttention { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                else if session.app == nil { Image(systemName: "pencil").foregroundStyle(Theme.muted) }
                else { Image(systemName: "checkmark.circle").foregroundStyle(Theme.green) }
                Text(session.status).lineLimit(1)
            }.font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func requestClose(_ session: BuilderSession) {
        guard !session.sending else { return }
        if !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pendingCloseSession = session }
        else { closeSession(session) }
    }

    private func closeSession(_ session: BuilderSession) {
        _ = builder.closeSession(session.id)
        pendingCloseSession = nil
    }

    private func stopSpeech() {
        speech.stop()
        speechSessionID = nil
    }

    private var websites: some View {
        NavigationStack {
            List {
                if builder.apps.isEmpty { Text("No saved websites yet.").foregroundStyle(Theme.muted) }
                ForEach(builder.apps) { app in
                    Button {
                        stopSpeech(); builder.open(app); showingWebsites = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.headline).foregroundStyle(.primary)
                            Text(app.prompt).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2)
                            Text(app.building ? "Building" : "Revision \(app.revision)").font(.caption).foregroundStyle(Theme.muted)
                        }.padding(.vertical, 4)
                    }
                    .accessibilityAddTraits(builder.selected?.id == app.id ? .isSelected : [])
                }
            }.navigationTitle("Websites").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingWebsites = false } } }
                .refreshable { do { await builder.load(try account.buildAPI) } catch { builder.error = error.localizedDescription } }
        }
    }
}
