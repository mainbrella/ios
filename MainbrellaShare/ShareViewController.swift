import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let host = UIHostingController(rootView: ShareView(providers: providers, finish: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }).preferredColorScheme(.dark).tint(Theme.blue))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        isModalInPresentation = true
    }
}

private struct ShareView: View {
    @StateObject private var store = ShareStore()
    let providers: [NSItemProvider]
    let finish: () -> Void
    let cancel: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                if !store.connected {
                    Section {
                        Text("Connect your account in Mainbrella, then share again.")
                    }
                } else if store.sent {
                    Section {
                        Label("Saved to workspace inbox", systemImage: "checkmark.circle").foregroundStyle(Theme.green)
                        if let workspace = store.selection { Text(workspace.name).foregroundStyle(Theme.muted) }
                        Button("Done", action: finish).frame(minHeight: 44)
                    }
                } else {
                    Section {
                        if store.loading && !store.hasLoaded { ProgressView("Loading workspaces…") }
                        if let error = store.syncError {
                            Text(error).foregroundStyle(.orange)
                            Button("Refresh workspaces") { Task { await store.refresh() } }
                        }
                        if store.hasLoaded && store.workspaces.isEmpty {
                            Text("No running workspaces. Start one from Mainbrella on the web, then share again.").foregroundStyle(Theme.muted)
                        } else if !store.workspaces.isEmpty {
                            Picker("Workspace", selection: $store.selection) {
                                Text("Choose a workspace").tag(Optional<Workspace>.none)
                                ForEach(store.workspaces) { workspace in
                                    Text("\(workspace.name) · \(workspace.id)").tag(Optional(workspace))
                                }
                            }.disabled(store.sending).accessibilityIdentifier("share-workspace")
                        }
                    } header: { Text("Destination") }
                    Section {
                        TextField("What should the agent do?", text: $store.instruction, axis: .vertical)
                            .lineLimit(2...6).focused($editing).disabled(store.sending)
                            .accessibilityLabel("Instruction for the agent")
                    } header: { Text("Instruction") }
                    Section {
                        if store.preparing { ProgressView("Preparing shared item…") }
                        if let payload = store.payload {
                            if !payload.text.isEmpty { Text(payload.text).lineLimit(8).textSelection(.enabled) }
                            if let image = payload.image {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                    .accessibilityLabel("Shared photo")
                            }
                        }
                    } header: { Text("Shared item") }
                    Section {
                        if let failure = store.failure { Text(failure).foregroundStyle(.orange) }
                        Button {
                            editing = false
                            Task { await store.send() }
                        } label: {
                            HStack {
                                Text(store.sending ? "Sending…" : "Send to workspace")
                                Spacer()
                                if store.sending { ProgressView() } else { Image(systemName: "paperplane") }
                            }.frame(minHeight: 44)
                        }.disabled(!store.canSend)
                    } footer: {
                        Text("Saved to the workspace inbox. An agent must read the inbox to act on your instruction.")
                    }
                }
            }.scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).background(Theme.background)
                .navigationTitle("Share to Mainbrella").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: cancel).disabled(store.sending)
                    }
                    if store.connected && !store.sent {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text(store.liveState.rawValue).font(.caption)
                                .foregroundStyle(store.liveState == .live ? Theme.green : Theme.muted)
                                .accessibilityLabel("Live updates: \(store.liveState.rawValue)")
                        }
                    }
                }
                .refreshable { await store.refresh() }
                .task {
                    guard store.connected else { return }
                    let preparing = Task { await store.prepare(providers) }
                    defer { preparing.cancel() }
                    await store.followActivity()
                }
                .onDisappear { store.stop() }
        }
    }
}
