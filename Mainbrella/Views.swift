import SwiftUI

enum Theme {
    static let background = Color(red: 0.045, green: 0.058, blue: 0.077)
    static let surface = Color(red: 0.085, green: 0.100, blue: 0.124)
    static let muted = Color(red: 0.66, green: 0.70, blue: 0.78)
    static let blue = Color(red: 0.29, green: 0.48, blue: 1)
    static let green = Color(red: 0.14, green: 0.82, blue: 0.65)
}

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
    @State private var destination: Destination = .inbox
    var body: some View {
        GeometryReader { geometry in
            let inspector = size == .regular && geometry.size.width >= 1100
            Group {
                if !store.connected {
                    NavigationStack { AccountView() }
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
            .onChange(of: store.connected) { _, _ in destination = .inbox }
            .task { await store.refresh() }
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
            VStack(alignment: .leading, spacing: 20) {
                if let error = store.syncError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                }
                if store.loading && !store.hasLoaded { ProgressView("Loading activity…") }
                if store.hasLoaded {
                    let jobs = store.jobs.values.flatMap { $0 }
                    if jobs.isEmpty {
                        Text("No execution activity yet.").foregroundStyle(Theme.muted)
                    } else {
                        if jobs.contains(where: \.running) {
                            SectionLabel(title: "Working", symbol: "circle.fill", color: Theme.blue, count: jobs.filter(\.running).count)
                            executionRows(running: true)
                        }
                        if jobs.contains(where: { !$0.running }) {
                            SectionLabel(title: "Finished", symbol: "checkmark.circle", color: Theme.muted, count: jobs.filter { !$0.running }.count)
                            executionRows(running: false)
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
    }
    @ViewBuilder private func executionRows(running: Bool) -> some View {
        ForEach(store.workspaces) { space in
            ForEach(store.jobs[space.id, default: []].filter { $0.running == running }) { job in
                HStack(spacing: 12) {
                    SymbolTile(symbol: job.running ? "terminal" : job.status == "succeeded" ? "checkmark" : "exclamationmark.circle",
                               color: job.running ? Theme.blue : job.status == "succeeded" ? Theme.green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(space.name).font(.subheadline.weight(.semibold))
                        Text("Execution \(job.id.prefix(8)) · \(job.status.replacingOccurrences(of: "_", with: " "))")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if running { ProgressView().accessibilityLabel("Execution running") }
                }.padding(.vertical, 8)
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
                    }
                    Button { selected = workspace; showPort = true } label: {
                        Label(store.previewBusy ? "Opening preview…" : "Open preview", systemImage: "arrow.up.right.square")
                            .frame(minHeight: 44)
                    }.disabled(store.previewBusy || workspace.status != "running")
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
            } message: { Text("The app server must already be running. Creates a protected link for up to 15 minutes. Existing grants can be revoked below.") }
    }
    private func formatted(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)?.formatted(date: .omitted, time: .shortened) ?? value
    }
}

struct AccountView: View {
    @EnvironmentObject var store: AppStore
    @State private var token = ""
    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: store.connected ? "Connected" : "Not connected")
                LabeledContent("API", value: ServiceURLs.api.host ?? "")
                HStack {
                    Text("API key")
                    SecureField("Paste your API key", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("API key")
                }
                Button(store.loading ? "Connecting…" : store.connected ? "Update API key" : "Connect") {
                    Task { if await store.connect(token: token) { token = "" } }
                }.disabled(store.loading || store.previewBusy || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link("Create an API key", destination: ServiceURLs.apiKeys)
            } header: { Text("Connection") } footer: {
                Text("Your key is stored in this device's Keychain. An active Mainbrella plan is required for previews and uploads.")
            }
            if store.connected {
                Section {
                    Button("Remove saved key", role: .destructive) { store.disconnect() }.disabled(store.loading || store.previewBusy)
                }
            }
        }.scrollContentBackground(.hidden).frame(maxWidth: 680).frame(maxWidth: .infinity).background(Theme.background)
            .navigationTitle(store.connected ? "Account" : "Connect to Mainbrella").navigationBarTitleDisplayMode(.inline)
    }
}
