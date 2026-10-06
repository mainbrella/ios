import SwiftUI
import PhotosUI
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

struct ExecutionView: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    let execution: Execution
    @State private var detail: ExecutionDetail?
    @State private var loading = false
    @State private var failure: String?
    @State private var updatedAt: Date?
    @State private var output = Output.standard
    @State private var copied = false
    @State private var loadID = UUID()

    private enum Output: String, CaseIterable { case standard = "Output", errors = "Errors" }
    private var text: String { output == .standard ? detail?.stdout ?? "" : detail?.stderr ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(workspace.name).font(.headline)
                HStack {
                    Text((detail?.execution ?? execution).statusLabel)
                    if let code = detail?.execution.exitCode ?? execution.exitCode { Text("· Exit \(code)") }
                }.font(.subheadline).foregroundStyle(Theme.muted)
                if let updatedAt {
                    Text("Loaded \(updatedAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            if let failure { Text(failure).font(.subheadline).foregroundStyle(.orange) }
            if let explanation = store.liveState.explanation {
                Text(explanation).font(.subheadline).foregroundStyle(Theme.muted)
            }
            Picker("Execution output", selection: $output) {
                ForEach(Output.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if loading && detail == nil {
                ProgressView("Loading execution…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Text(text.isEmpty ? "No \(output == .errors ? "error " : "")output captured." : text)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(minWidth: max(0, geometry.size.width - 24),
                                   minHeight: max(0, geometry.size.height - 24), alignment: .topLeading)
                            .padding(12)
                    }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 24) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy \(output.rawValue.lowercased())", systemImage: copied ? "checkmark" : "doc.on.doc").frame(minHeight: 44) }
                    ShareLink(item: text) {
                        Label("Share \(output.rawValue.lowercased())", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                    }.accessibilityIdentifier("share-execution-output")
                }.disabled(text.isEmpty)
            }
        }.padding(16).frame(maxWidth: 800).frame(maxWidth: .infinity).background(Theme.background)
            .navigationTitle("Execution").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load() } } label: {
                        if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }.disabled(loading).accessibilityLabel("Refresh execution")
                }
            }
            .task(id: store.executionVersions[workspace.id, default: 0]) { await load() }
            .onChange(of: output) { _, _ in copied = false }
    }

    private func load() async {
        let id = UUID()
        loadID = id
        loading = true; failure = nil
        defer { if loadID == id { loading = false } }
        do {
            let result = try await store.api.execution(execution.id, workspace: workspace)
            guard !Task.isCancelled, loadID == id else { return }
            detail = result; updatedAt = Date(); copied = false
            if detail?.stdout.isEmpty == true && detail?.stderr.isEmpty == false { output = .errors }
        } catch { if !Task.isCancelled, loadID == id { failure = error.localizedDescription } }
    }
}

struct WorkspaceInboxView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    @State private var instruction = ""
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var attachment: WorkspaceAttachment?
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var cameraDenied = false
    @State private var preparationID = UUID()
    @State private var loadingPhoto = false
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?
    @State private var attempt: InboxAttempt?
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section {
                Text(workspace.name).font(.headline)
                TextField("What should the agent do?", text: $instruction, axis: .vertical)
                    .lineLimit(2...6).focused($editing).accessibilityLabel("Instruction for the agent")
                    .disabled(sending || sent)
            } header: { Text("Instruction") }
            if !sent {
                Section {
                    TextField("Text, link, or clipboard content", text: $text, axis: .vertical)
                        .lineLimit(3...8).accessibilityLabel("Context for the agent").disabled(sending)
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { text = value }
                    }.disabled(sending)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(image == nil ? "Attach a photo or screenshot" : "Replace photo", systemImage: "photo")
                            .frame(minHeight: 44)
                    }.disabled(sending || loadingPhoto)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { Task { await openCamera() } } label: {
                            Label("Take a photo", systemImage: "camera").frame(minHeight: 44)
                        }.disabled(sending || loadingPhoto)
                    }
                    Button { showFiles = true } label: {
                        Label("Attach a file", systemImage: "doc.badge.plus").frame(minHeight: 44)
                    }.disabled(sending || loadingPhoto)
                    if loadingPhoto { ProgressView("Preparing attachment…") }
                    if cameraDenied {
                        Link("Allow camera access in Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                            .accessibilityLabel("Attached photo")
                    }
                    if let attachment {
                        Label(attachment.name, systemImage: attachment.source == "ios-file" ? "doc" : "photo")
                            .font(.subheadline).lineLimit(2)
                        Text(attachment.data.count.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(Theme.muted)
                        Button("Remove attachment", role: .destructive) { clearAttachment() }
                            .disabled(sending || loadingPhoto)
                    }
                } header: { Text("Context") }
            }
            Section {
                if !workspaceAvailable && !sent { Text("This workspace has stopped or been replaced. Close this sheet and choose a running workspace.").foregroundStyle(.orange) }
                if let failure { Text(failure).foregroundStyle(.orange) }
                if sent {
                    Label("Saved to workspace inbox", systemImage: "checkmark.circle").foregroundStyle(Theme.green)
                    Button("Done") { dismiss() }
                } else {
                    Button {
                        editing = false
                        Task { await send() }
                    } label: {
                        HStack { Text(sending ? "Sending…" : "Send to workspace"); Spacer(); if sending { ProgressView() } else { Image(systemName: "paperplane") } }
                            .frame(minHeight: 44)
                    }.disabled(sending || loadingPhoto || !workspaceAvailable || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("submit-inbox-message")
                }
            } footer: {
                Text("One attachment per message. Files must be 1 MiB or smaller; photos are resized. An agent needs to read the workspace inbox to act on your instruction.")
            }
        }.scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).background(Theme.background)
            .navigationTitle("Send to workspace").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(sending) } }
            .interactiveDismissDisabled(sending)
            .task(id: photo) { await loadPhoto() }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCapture { captured in
                    showCamera = false
                    guard let captured else { return }
                    photo = nil
                    preparePhoto(captured, source: "ios-camera")
                }.ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): Task { await loadFile(url) }
                case .failure(let error): failure = error.localizedDescription
                }
            }
    }

    private var workspaceAvailable: Bool {
        store.workspaces.contains { $0.id == workspace.id && $0.createdAt == workspace.createdAt && $0.status == "running" }
    }

    private func clearAttachment() {
        preparationID = UUID()
        photo = nil; image = nil; attachment = nil; loadingPhoto = false
    }

    private func openCamera() async {
        cameraDenied = false
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        if allowed { showCamera = true }
        else { cameraDenied = true }
    }

    private func preparePhoto(_ image: UIImage, source: String) {
        do {
            let result = try WorkspaceAttachment.photo(image, source: source)
            self.image = UIImage(data: result.data); attachment = result; failure = nil
        } catch { failure = "This photo couldn't be prepared. Choose another photo or send text." }
    }

    private func loadPhoto() async {
        guard let photo else { return }
        let id = UUID(); preparationID = id
        loadingPhoto = true; failure = nil
        defer { if preparationID == id { loadingPhoto = false } }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw APIError.response(0, "photo") }
            let image = try InboxAttachment.image(data: data)
            guard !Task.isCancelled, preparationID == id else { return }
            preparePhoto(image, source: "ios-photo")
        } catch { if !Task.isCancelled, preparationID == id { failure = "This photo couldn't be prepared. Choose another photo or send text." } }
    }

    private func loadFile(_ url: URL) async {
        let id = UUID(); preparationID = id
        loadingPhoto = true; failure = nil
        defer { if preparationID == id { loadingPhoto = false } }
        do {
            let result = try await Task.detached { try WorkspaceAttachment.document(url) }.value
            guard preparationID == id else { return }
            photo = nil; image = nil; attachment = result
        } catch { if preparationID == id { failure = error.localizedDescription } }
    }

    private func send() async {
        guard workspaceAvailable, !sending, !loadingPhoto else { return }
        sending = true; failure = nil
        defer { sending = false }
        do {
            let draft = InboxDraft(instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                                   text: text, attachment: attachment)
            if attempt?.draft != draft { attempt = InboxAttempt(draft: draft, workspace: workspace) }
            guard let attempt else { return }
            try await store.api.sendInbox(attempt.message, attachment: attempt.draft.attachment?.data, id: attempt.id, workspace: workspace)
            sent = true
        } catch { failure = error.localizedDescription + " Your input is still here; try again." }
    }
}
