import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case inbox = "Activity", projects = "Projects", previews = "Previews", account = "Account"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .inbox: "tray"; case .projects: "folder"; case .previews: "rectangle.on.rectangle"; case .account: "person.crop.circle" }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.horizontalSizeClass) private var size
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var destination: Destination = .inbox
    @State private var showingSplash = true
    @State private var signInRequired = false
    var body: some View {
        GeometryReader { geometry in
            let inspector = size == .regular && geometry.size.width >= 1100
            Group {
                if !store.connected {
                    NavigationStack {
                        if signInRequired { AccountView() }
                        else { WelcomeView() }
                    }
                } else if size == .regular {
                    NavigationSplitView {
                        List(Destination.allCases) { item in
                            Button { destination = item } label: {
                                Label(item.rawValue, systemImage: item.symbol).foregroundStyle(destination == item ? Theme.blue : .primary).frame(minHeight: 44)
                            }
                        }.navigationTitle("Mainbrella").scrollContentBackground(.hidden)
                            .background(Theme.background).navigationSplitViewColumnWidth(210)
                    } detail: {
                        HStack(spacing: 0) {
                            NavigationStack { content }.frame(maxWidth: .infinity)
                            if inspector && destination != .account, let preview = store.preview {
                                Divider()
                                PreviewView(session: preview, embedded: true).id(preview.id)
                                    .frame(width: 350).background(Theme.surface)
                            }
                        }
                    }
                } else {
                    TabView(selection: $destination) {
                        ForEach(Destination.allCases) { item in
                            NavigationStack { screen(item) }.tabItem { Label(item.rawValue, systemImage: item.symbol) }.tag(item)
                        }
                    }
                }
            }
            .background(Theme.background)
            .sheet(item: Binding(get: { inspector && destination != .account ? nil : store.preview }, set: { store.preview = $0 })) { preview in
                NavigationStack { PreviewView(session: preview) }.environmentObject(store)
            }
            .alert("Unable to complete request", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
            .onChange(of: store.connected) { wasConnected, connected in
                destination = .inbox
                signInRequired = wasConnected && !connected
            }
            .task(id: LiveSessionIdentity(revision: store.revision, active: scenePhase == .active)) {
                if scenePhase == .active { await store.followActivity() }
            }
            .accessibilityHidden(showingSplash)
            .allowsHitTesting(!showingSplash)
            .overlay {
                if showingSplash { SplashView().transition(.opacity) }
            }
            .task {
                // A short launch transition; account and activity loading run independently.
                // Never hold the app on a splash while waiting for the network.
                do { try await Task.sleep(for: .milliseconds(600)) }
                catch { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showingSplash = false }
            }
        }
    }
    @ViewBuilder private var content: some View { screen(destination) }
    @ViewBuilder private func screen(_ destination: Destination) -> some View {
        switch destination {
        case .inbox: InboxView()
        case .projects: WorkspacesView(previewsOnly: false)
        case .previews: WorkspacesView(previewsOnly: true)
        case .account: AccountView()
        }
    }
}

private struct LiveSessionIdentity: Equatable {
    let revision: Int
    let active: Bool
}

struct LiveStatus: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Label(store.liveState.rawValue, systemImage: store.liveState == .live ? "bolt.horizontal.circle" : "wifi.exclamationmark")
            .labelStyle(.titleAndIcon)
            .font(.caption).foregroundStyle(store.liveState == .live ? Theme.green : Theme.muted)
            .accessibilityLabel("Live updates: \(store.liveState.rawValue)")
            .accessibilityIdentifier("live-status")
    }
}

struct SectionLabel: View {
    let title: String
    let symbol: String
    let color: Color
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).font(.subheadline.weight(.semibold))
            Text("\(count)").font(.caption).foregroundStyle(Theme.muted)
            Spacer()
        }.accessibilityElement(children: .combine)
    }
}

struct InboxView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let explanation = store.liveState.explanation {
                    Text(explanation).font(.subheadline).foregroundStyle(Theme.muted)
                }
                if let error = store.syncError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                }
                if store.loading && !store.hasLoaded { ProgressView("Loading activity…") }
                if store.hasLoaded {
                    let jobs = store.jobs.values.flatMap { $0 }
                    if jobs.isEmpty && store.syncError == nil {
                        Text("No execution activity yet.").foregroundStyle(Theme.muted)
                    } else {
                        if jobs.contains(where: \.needsReview) {
                            SectionLabel(title: "Needs review", symbol: "exclamationmark.circle", color: .orange, count: jobs.filter(\.needsReview).count)
                            executionRows(group: .review)
                        }
                        if jobs.contains(where: \.running) {
                            SectionLabel(title: "Working", symbol: "circle.fill", color: Theme.blue, count: jobs.filter(\.running).count)
                            executionRows(group: .working)
                        }
                        if jobs.contains(where: { !$0.running && !$0.needsReview }) {
                            SectionLabel(title: "Finished", symbol: "checkmark.circle", color: Theme.muted, count: jobs.filter { !$0.running && !$0.needsReview }.count)
                            executionRows(group: .finished)
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { LiveStatus() } }
            .refreshable { await store.refresh() }
    }
    private enum JobGroup { case review, working, finished
        func includes(_ job: Execution) -> Bool {
            switch self { case .review: job.needsReview; case .working: job.running; case .finished: !job.running && !job.needsReview }
        }
    }
    @ViewBuilder private func executionRows(group: JobGroup) -> some View {
        ForEach(store.workspaces) { space in
            ForEach(store.jobs[space.id, default: []].filter { group.includes($0) }) { job in
                NavigationLink {
                    ExecutionView(workspace: space, execution: job)
                } label: { HStack(spacing: 12) {
                    SymbolTile(symbol: job.running ? "terminal" : job.status == "succeeded" ? "checkmark" : "exclamationmark.circle",
                               color: job.running ? Theme.blue : job.status == "succeeded" ? Theme.green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(space.name).font(.subheadline.weight(.semibold))
                        Text("\(job.statusLabel) · \(job.id.prefix(8))")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                }.padding(.vertical, 8).contentShape(Rectangle()) }.buttonStyle(.plain)
                    .accessibilityIdentifier("execution-\(space.id)-\(job.id)")
            }
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 21, weight: .medium)).foregroundStyle(color)
            .frame(width: 40, height: 44).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}

struct ActionStyle: ButtonStyle {
    var color: Color = Theme.blue
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 16).frame(minHeight: 44)
            .background(color.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
    }
}

struct WorkspacesView: View {
    @EnvironmentObject var store: AppStore
    let previewsOnly: Bool
    @State private var selected: Workspace?
    @State private var port = "3000"
    @State private var showPort = false
    @State private var inboxWorkspace: Workspace?
    @State private var revocation: PreviewRevocation?
    var body: some View {
        List {
            if let error = store.syncError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if store.loading && !store.hasLoaded { ProgressView("Loading workspaces…") }
            if store.hasLoaded && store.workspaces.isEmpty {
                Text("No active workspaces. Start one from Mainbrella on the web.").foregroundStyle(Theme.muted).listRowBackground(Theme.background)
            }
            ForEach(store.workspaces) { workspace in
                Section {
                    HStack {
                        Label(workspace.name, systemImage: "folder")
                        Spacer()
                        Text(workspace.status.capitalized).font(.caption).foregroundStyle(workspace.status == "running" ? Theme.green : Theme.muted)
                    }
                    if !previewsOnly {
                        LabeledContent("Workspace", value: workspace.id).font(.caption)
                        LabeledContent("Expires", value: formatted(workspace.expiresAt)).font(.caption)
                        Button { inboxWorkspace = workspace } label: {
                            Label("Send to workspace", systemImage: "paperplane").frame(minHeight: 44)
                        }.disabled(workspace.status != "running").accessibilityIdentifier("send-inbox-\(workspace.id)")
                    }
                    Button { selected = workspace; showPort = true } label: {
                        Label(store.previewBusy ? "Opening preview…" : "Open preview", systemImage: "arrow.up.right.square")
                            .frame(minHeight: 44)
                    }.disabled(store.previewBusy || workspace.status != "running").accessibilityIdentifier("open-preview-\(workspace.id)")
                    ForEach(store.grants[workspace.id, default: []]) { grant in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Port \(String(grant.port))")
                                Text("Expires \(Date(timeIntervalSince1970: grant.expiresAt / 1000).formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { revocation = PreviewRevocation(workspace: workspace, grant: grant) }.frame(minHeight: 44)
                        }
                    }
                }.listRowBackground(Theme.surface)
            }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(previewsOnly ? "Previews" : "Projects").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { LiveStatus() } }
            .refreshable { await store.refresh() }
            .sheet(item: $inboxWorkspace) { workspace in
                NavigationStack { WorkspaceInboxView(workspace: workspace) }.environmentObject(store)
            }
            .confirmationDialog("Revoke protected preview?", isPresented: Binding(get: { revocation != nil }, set: { if !$0 { revocation = nil } }), titleVisibility: .visible) {
                if let item = revocation {
                    Button("Revoke port \(String(item.grant.port))", role: .destructive) { Task { await store.revoke(item.workspace, grant: item.grant) }; revocation = nil }
                }
            } message: { Text("Anyone using this link will lose access.") }
            .alert("Open preview", isPresented: $showPort) {
                TextField("Port", text: $port).keyboardType(.numberPad)
                Button("Open") {
                    guard let value = Int(port), (1024...65535).contains(value), let workspace = selected else { store.error = "Enter a port between 1024 and 65535."; return }
                    Task { await store.openPreview(workspace, port: value) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The app server must already be running. Creates a protected link for up to 15 minutes. Existing grants can be revoked below.") }
    }
    private func formatted(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)?.formatted(date: .omitted, time: .shortened) ?? value
    }
}

private struct PreviewRevocation {
    let workspace: Workspace
    let grant: PreviewGrant
}
