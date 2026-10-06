import SwiftUI

enum Theme {
    static let background = Color(red: 0.045, green: 0.058, blue: 0.077)
    static let surface = Color(red: 0.085, green: 0.100, blue: 0.124)
    static let muted = Color(red: 0.66, green: 0.70, blue: 0.78)
    static let blue = Color(red: 0.29, green: 0.48, blue: 1)
    static let green = Color(red: 0.14, green: 0.82, blue: 0.65)
}

enum Destination: String, CaseIterable, Identifiable {
    case inbox = "Needs Me", projects = "Projects", previews = "Previews", account = "Account"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .inbox: "tray"; case .projects: "folder"; case .previews: "rectangle.on.rectangle"; case .account: "person.crop.circle" }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.horizontalSizeClass) private var size
    @Environment(\.scenePhase) private var phase
    @State private var destination: Destination = .inbox
    var body: some View {
        GeometryReader { geometry in
            let inspector = size == .regular && geometry.size.width >= 1100
            Group {
                if size == .regular {
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
                            if inspector && destination != .account {
                                Divider()
                                Group {
                                    if let preview = store.preview { PreviewView(session: preview, embedded: true).id(preview.id) }
                                    else { ContentUnavailableView("Preview", systemImage: "rectangle.on.rectangle", description: Text("Open a workspace preview to inspect it here.")) }
                                }.frame(width: 350).background(Theme.surface)
                            }
                        }
                    }
                } else {
                    TabView(selection: $destination) {
                        ForEach(Destination.allCases) { item in
                            NavigationStack { screen(item) }.tabItem { Label(item == .inbox ? "Inbox" : item.rawValue, systemImage: item.symbol) }.tag(item)
                                .badge(item == .inbox ? store.approvals.count + (store.demo ? 1 : 0) : 0)
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
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(15)) } catch { break }
                }
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

struct SectionLabel: View {
    let title: String
    let symbol: String
    let color: Color
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).font(.title3.weight(.semibold))
            Text("\(count)").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4).background(.white.opacity(0.07), in: Capsule())
            Spacer()
        }.accessibilityElement(children: .combine)
    }
}

struct InboxView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    Image(systemName: "umbrella.fill").font(.system(size: 34)).foregroundStyle(Theme.blue).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mainbrella").font(.title.weight(.bold))
                        Text("Your agents need you.").font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                }
                if store.demo {
                    HStack {
                        Label("Demo workspace", systemImage: "play.circle").font(.caption.weight(.medium))
                        Spacer()
                        NavigationLink("Connect account") { AccountView() }.font(.caption.weight(.semibold)).frame(minHeight: 44)
                    }.foregroundStyle(Theme.muted)
                }
                if let error = store.syncError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if store.loading && !store.demo { ProgressView("Refreshing workspaces…").font(.caption) }
                VStack(spacing: 12) {
                    SectionLabel(title: "Needs Me", symbol: "exclamationmark.circle.fill", color: .orange, count: store.approvals.count + (store.demo ? 1 : 0))
                    if store.demo {
                        VStack(spacing: 0) {
                            ForEach(store.approvals) { approval in
                                ApprovalRow(approval: approval)
                                Divider().padding(.leading, 64)
                            }
                            HStack(alignment: .top, spacing: 12) {
                                SymbolTile(symbol: "doc.richtext", color: Theme.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Preview ready for mainbrella/web").font(.subheadline.weight(.semibold))
                                    Text("Web Agent · 12 min ago").font(.caption).foregroundStyle(Theme.muted)
                                    Button("Open preview") { Task { await store.openPreview(.demo) } }.buttonStyle(ActionStyle(color: Theme.blue))
                                }
                                Spacer(minLength: 0)
                            }.padding(16)
                        }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        Text("Agent approvals aren't available yet. Your workspaces and previews are connected.").font(.subheadline).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(spacing: 12) {
                    SectionLabel(title: "Working", symbol: "circle.fill", color: Theme.green, count: store.demo ? 2 : store.jobs.values.flatMap { $0 }.filter(\.running).count)
                    if store.demo {
                        VStack(spacing: 0) {
                            DemoJobRow(title: "Pricing page redesign", subtitle: "Frontend Agent · 17/23 tests passed", symbol: "terminal", progress: 0.74)
                            Divider().padding(.leading, 64)
                            DemoJobRow(title: "Groupicorn iOS", subtitle: "iOS Agent · Building preview", symbol: "hammer", progress: 0.62)
                        }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    } else { executionRows(running: true) }
                }
                VStack(spacing: 12) {
                    SectionLabel(title: "Done", symbol: "checkmark.circle.fill", color: Theme.green, count: store.demo ? 2 : store.jobs.values.flatMap { $0 }.filter { !$0.running }.count)
                    if store.demo {
                        VStack(spacing: 0) {
                            completedRow("Fix onboarding copy", subtitle: "mainbrella/web · Completed 2h ago", symbol: "chevron.left.forwardslash.chevron.right")
                            Divider().padding(.leading, 64)
                            completedRow("Update analytics schema", subtitle: "Data Agent · Completed 4h ago", symbol: "externaldrive")
                        }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    } else { executionRows(running: false) }
                }
                if let notice = store.notice {
                    HStack { Text(notice).font(.caption); Spacer(); Button("Dismiss") { store.notice = nil }.font(.caption).frame(minHeight: 44) }.foregroundStyle(Theme.muted)
                }
            }.padding(20).frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }.background(Theme.background).navigationBarHidden(true).refreshable { await store.refresh() }
    }
    @ViewBuilder private func executionRows(running: Bool) -> some View {
        let spaces = store.workspaces.filter { space in store.jobs[space.id, default: []].contains { $0.running == running } }
        if spaces.isEmpty { Text(running ? "No work is running." : "No completed work yet.").font(.subheadline).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading) }
        ForEach(spaces) { space in
            ForEach(store.jobs[space.id, default: []].filter { $0.running == running }) { job in
                HStack {
                    SymbolTile(symbol: running ? "terminal" : "checkmark", color: running ? Theme.blue : Theme.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(space.name).font(.subheadline.weight(.semibold))
                        Text("Execution \(job.id.prefix(8)) · \(job.status.replacingOccurrences(of: "_", with: " "))").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if running { ProgressView().accessibilityLabel("Execution running") }
                }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private func completedRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, color: Theme.green)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.semibold)); Text(subtitle).font(.caption).foregroundStyle(Theme.muted) }
            Spacer(minLength: 4)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        }.padding(16)
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

struct ApprovalRow: View {
    @EnvironmentObject var store: AppStore
    let approval: Approval
    @State private var busy = false
    @State private var confirming = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: approval.symbol, color: approval.sensitive ? .orange : .purple)
            VStack(alignment: .leading, spacing: 7) {
                Text(approval.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(approval.agent).font(.caption).foregroundStyle(Theme.muted)
                ViewThatFits(in: .horizontal) {
                    HStack { approveButton; denyButton }
                    VStack(alignment: .leading) { approveButton; denyButton }
                }.disabled(busy)
            }
            Spacer(minLength: 0)
        }.padding(16)
        .confirmationDialog("Approve this demo request?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Approve") { Task { busy = true; await store.decide(approval, approve: true); busy = false } }
        } message: { Text(approval.title) }
    }
    private var approveButton: some View {
        Button(busy ? "Authenticating…" : "Approve") { confirming = true }.buttonStyle(ActionStyle(color: Color(red: 0.03, green: 0.53, blue: 0.42)))
    }
    private var denyButton: some View {
        Button("Deny") { Task { await store.decide(approval, approve: false) } }.buttonStyle(ActionStyle(color: .white.opacity(0.07)))
    }
}

struct DemoJobRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let progress: Double
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: symbol, color: Theme.blue)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(title).font(.subheadline.weight(.semibold)); Spacer(); Text("Running").font(.caption).foregroundStyle(Theme.blue) }
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
                HStack { ProgressView(value: progress).tint(Theme.green); Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(Theme.muted) }
            }
        }.padding(16)
    }
}

struct WorkspacesView: View {
    @EnvironmentObject var store: AppStore
    let previewsOnly: Bool
    @State private var selected: Workspace?
    @State private var port = "3000"
    @State private var showPort = false
    var body: some View {
        List {
            if let error = store.syncError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if store.demo { Text("Demo mode · Connect your account for live workspaces.").font(.caption).foregroundStyle(Theme.muted).listRowBackground(Theme.background) }
            if store.workspaces.isEmpty {
                Text("No active workspaces. Start one from Mainbrella on the web.").foregroundStyle(Theme.muted).listRowBackground(Theme.background)
            }
            ForEach(store.workspaces) { workspace in
                Section {
                    HStack {
                        Label(workspace.name, systemImage: "folder")
                        Spacer()
                        Text(workspace.status.capitalized).font(.caption).foregroundStyle(Theme.green)
                    }
                    if !previewsOnly {
                        LabeledContent("Workspace", value: workspace.id).font(.caption)
                        LabeledContent("Expires", value: formatted(workspace.expiresAt)).font(.caption)
                    }
                    Button { selected = workspace; showPort = true } label: {
                        Label(store.previewBusy ? "Opening preview…" : "Open preview", systemImage: "arrow.up.right.square")
                            .frame(minHeight: 44)
                    }.disabled(store.previewBusy)
                    ForEach(store.grants[workspace.id, default: []]) { grant in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Port \(grant.port)")
                                Text("Expires \(Date(timeIntervalSince1970: grant.expiresAt / 1000).formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { Task { await store.revoke(workspace, grant: grant) } }.frame(minHeight: 44)
                        }
                    }
                }.listRowBackground(Theme.surface)
            }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(previewsOnly ? "Previews" : "Projects").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .alert("Open preview", isPresented: $showPort) {
                TextField("Port", text: $port).keyboardType(.numberPad)
                Button("Open") {
                    guard let value = Int(port), (1024...65535).contains(value), let workspace = selected else { store.error = "Enter a port between 1024 and 65535."; return }
                    Task { await store.openPreview(workspace, port: value) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text(store.demo ? "Open the local demo preview." : "The app server must already be running. Creates a protected link for up to 15 minutes. Existing grants can be revoked below.") }
    }
    private func formatted(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)?.formatted(date: .omitted, time: .shortened) ?? value
    }
}

struct AccountView: View {
    @EnvironmentObject var store: AppStore
    @State private var endpoint = ""
    @State private var token = ""
    var body: some View {
        Form {
            Section {
                LabeledContent("Mode", value: store.demo ? "Demo" : "Live")
                TextField("API address", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API key", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(store.loading ? "Connecting…" : "Connect") { Task { if await store.connect(endpoint: endpoint, token: token) { token = "" } } }.disabled(store.loading || token.isEmpty)
                Link("Create an API key", destination: URL(string: "https://mainbrella.com/api-keys/")!)
            } header: { Text("Connection") } footer: { Text("Your key is stored in this device's Keychain. An active Mainbrella plan is required for previews and uploads.") }
            Section {
                Button("Try demo") { store.useDemo() }.disabled(store.loading)
                if store.connected { Button("Remove saved key", role: .destructive) { store.disconnect() }.disabled(store.loading) }
            }
            Section("This first version") {
                Text("Live workspaces, execution status, protected previews, and screenshot feedback uploads.")
                Text("Approvals are demonstrated locally. Push notifications and automatic agent handoff need backend support.").foregroundStyle(Theme.muted)
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
            .onAppear { endpoint = store.endpoint }
    }
}
