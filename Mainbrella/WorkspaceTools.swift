import SwiftUI
import PhotosUI
import ImageIO

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
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy \(output.rawValue.lowercased())", systemImage: copied ? "checkmark" : "doc.on.doc").frame(minHeight: 44) }
                    .disabled(text.isEmpty)
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
    @State private var attachment: Data?
    @State private var loadingPhoto = false
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?
    @State private var messageID = UUID().uuidString.lowercased()
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
                    }.disabled(sending)
                    if loadingPhoto { ProgressView("Preparing photo…") }
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                            .accessibilityLabel("Attached photo")
                        Button("Remove photo", role: .destructive) { photo = nil; self.image = nil; attachment = nil }
                            .disabled(sending)
                    }
                } header: { Text("Context") }
            }
            Section {
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
                    }.disabled(sending || loadingPhoto || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("Saved in this workspace's inbox. An agent needs to read the inbox to act on your instruction.")
            }
        }.scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).background(Theme.background)
            .navigationTitle("Send to workspace").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(sending) } }
            .interactiveDismissDisabled(sending)
            .task(id: photo) { await loadPhoto() }
    }

    private func loadPhoto() async {
        guard let photo else { return }
        loadingPhoto = true; failure = nil
        defer { if self.photo == photo { loadingPhoto = false } }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048
                  ] as CFDictionary) else { throw APIError.response(0, "photo") }
            let image = UIImage(cgImage: thumbnail)
            let bytes = try FeedbackEncoder.jpeg(image)
            guard !Task.isCancelled else { return }
            self.image = image; attachment = bytes
        } catch { if !Task.isCancelled { failure = "This photo couldn't be prepared. Choose another photo or send text." } }
    }

    private func send() async {
        sending = true; failure = nil
        defer { sending = false }
        do {
            let message = InboxMessage(version: 1, createdAt: ISO8601DateFormatter().string(from: Date()),
                workspaceID: workspace.id, generation: workspace.createdAt,
                source: attachment == nil ? "ios-text" : "ios-photo",
                instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines), text: text,
                attachment: attachment == nil ? nil : "message-\(messageID).jpg")
            try await store.api.sendInbox(message, attachment: attachment, id: messageID, workspace: workspace)
            sent = true
        } catch { failure = "Your message wasn't fully saved. Your input is still here; try again." }
    }
}
