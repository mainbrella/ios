import SwiftUI
import WebKit
import PencilKit

@MainActor final class PreviewController: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    @Published var loading = true
    @Published var failure: String?
    var messages: [String] = []
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: """
        (() => {
          const report = value => window.webkit.messageHandlers.diagnostics.postMessage(String(value).slice(0, 2000));
          window.addEventListener('error', e => report('error: ' + e.message));
          window.addEventListener('unhandledrejection', e => report('rejection: ' + String(e.reason)));
          const original = console.error;
          console.error = (...args) => { report('console.error: ' + args.map(String).join(' ')); original.apply(console, args); };
          const warn = console.warn;
          console.warn = (...args) => { report('console.warn: ' + args.map(String).join(' ')); warn.apply(console, args); };
          const fetch = window.fetch;
          window.fetch = function(...args) {
            return fetch.apply(this, args).then(response => {
              if (!response.ok) report('fetch: HTTP ' + response.status + ' ' + response.url);
              return response;
            }, error => { report('fetch failed: ' + String(error)); throw error; });
          };
          const send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.send = function(...args) {
            this.addEventListener('error', () => report('XHR network failure: ' + this.responseURL), { once: true });
            this.addEventListener('load', () => { if (this.status >= 400) report('XHR: HTTP ' + this.status + ' ' + this.responseURL); }, { once: true });
            return send.apply(this, args);
          };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(WeakMessageHandler(self), name: "diagnostics")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Theme.background)
    }
    func stop() {
        webView.stopLoading()
    }
    func load(_ session: PreviewSession) {
        webView.load(URLRequest(url: session.url))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? String else { return }
        messages.append(String(value.prefix(2000)))
        if messages.count > 50 { messages.removeFirst(messages.count - 50) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; failure = nil }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; failure = nil; messages = [] }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loading = false; failure = "This preview couldn't load. Its link or workspace may have expired."
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            messages.append("Navigation: HTTP \(response.statusCode)")
        }
        decisionHandler(.allow)
    }
    func pageMetrics() async -> [String: Double] {
        let script = """
        (() => ({width: innerWidth, height: innerHeight, scrollX, scrollY,
          documentWidth: document.documentElement.scrollWidth,
          documentHeight: document.documentElement.scrollHeight,
          visualWidth: visualViewport?.width ?? innerWidth,
          visualHeight: visualViewport?.height ?? innerHeight,
          visualScale: visualViewport?.scale ?? 1, pixelRatio: devicePixelRatio}))()
        """
        return (try? await webView.evaluateJavaScript(script)) as? [String: Double] ?? [:]
    }
    func capture() async throws -> UIImage {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        return try await webView.takeSnapshot(configuration: config)
    }
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PreviewController?
    init(_ owner: PreviewController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

struct WebPreview: UIViewRepresentable {
    let controller: PreviewController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct Snapshot: Identifiable {
    let id = UUID()
    let image: UIImage
    let report: FeedbackReport
}

struct FeedbackReport: Codable {
    let version: Int
    let capturedAt: String
    let workspaceID: String
    let generation: String
    let url: String
    let device: String
    let systemVersion: String
    let viewportWidth: Double
    let viewportHeight: Double
    let scale: Double
    let safeArea: [String: Double]
    let orientation: String
    let diagnostics: [String]
    let pageMetrics: [String: Double]
    var instruction: String
    var screenshot: String
}

struct PreviewView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let session: PreviewSession
    var embedded = false
    @StateObject private var controller = PreviewController()
    @State private var snapshot: Snapshot?
    @State private var capturing = false
    var body: some View {
        VStack(spacing: 0) {
            if embedded {
                HStack { Label("Preview", systemImage: "globe").font(.headline); Spacer(); Button { store.preview = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Close preview") }.padding(.horizontal, 12)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.workspace.name).font(.subheadline.weight(.semibold))
                    Text("Protected preview · expires \(session.expiresAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { controller.load(session) } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("Reload preview")
            }.padding(.horizontal, 16).padding(.vertical, 8)
            ZStack {
                WebPreview(controller: controller)
                if controller.loading { ProgressView("Loading preview…").padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)) }
                if let failure = controller.failure {
                    ContentUnavailableView { Label("Preview unavailable", systemImage: "wifi.exclamationmark") } description: { Text(failure) } actions: { Button("Reload") { controller.load(session) } }.background(Theme.background)
                }
            }
            Button { Task { await capture() } } label: {
                Label(capturing ? "Capturing…" : "Screenshot & annotate", systemImage: "viewfinder").frame(maxWidth: .infinity)
            }.buttonStyle(ActionStyle()).padding(16).disabled(controller.loading || controller.failure != nil || capturing)
        }.background(Theme.background).navigationTitle("Preview").navigationBarTitleDisplayMode(.inline)
            .toolbar { if !embedded { ToolbarItem(placement: .topBarLeading) { Button("Done") { store.preview = nil; dismiss() } } } }
            .onAppear { controller.load(session) }.onDisappear { controller.stop() }
            .sheet(item: $snapshot) { snapshot in
                NavigationStack { FeedbackView(snapshot: snapshot, workspace: session.workspace) }.environmentObject(store)
            }
    }
    private func capture() async {
        capturing = true
        defer { capturing = false }
        do {
            let image = try await controller.capture()
            let web = controller.webView
            let inset = web.safeAreaInsets
            let report = FeedbackReport(version: 1, capturedAt: ISO8601DateFormatter().string(from: Date()), workspaceID: session.workspace.id,
                generation: session.workspace.createdAt, url: web.url?.absoluteString ?? session.url.absoluteString, device: UIDevice.current.model,
                systemVersion: UIDevice.current.systemVersion, viewportWidth: web.bounds.width, viewportHeight: web.bounds.height,
                scale: web.traitCollection.displayScale, safeArea: ["top": inset.top, "bottom": inset.bottom, "left": inset.left, "right": inset.right],
                orientation: web.window?.windowScene?.interfaceOrientation.isLandscape == true ? "landscape" : "portrait", diagnostics: controller.messages,
                pageMetrics: await controller.pageMetrics(), instruction: "", screenshot: "")
            snapshot = Snapshot(image: image, report: report)
        } catch { store.error = "The screenshot couldn't be captured. Please try again." }
    }
}

struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .systemOrange, width: 4)
        canvas.isScrollEnabled = false
        canvas.isAccessibilityElement = true
        canvas.accessibilityLabel = "Screenshot annotation canvas"
        canvas.accessibilityIdentifier = "annotationCanvas"
        canvas.delegate = context.coordinator
        return canvas
    }
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvas
        init(_ parent: DrawingCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { parent.drawing = canvasView.drawing }
    }
}

struct FeedbackView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let snapshot: Snapshot
    let workspace: Workspace
    @State private var drawing = PKDrawing()
    @State private var instruction = ""
    @State private var canvasSize = CGSize.zero
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?
    @State private var reportID = UUID().uuidString.lowercased()
    @FocusState private var editing: Bool
    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let ratio = snapshot.image.size.width / snapshot.image.size.height
                let width = min(geometry.size.width, geometry.size.height * ratio)
                let height = width / ratio
                ZStack {
                    Image(uiImage: snapshot.image).resizable().accessibilityLabel("Captured preview screenshot")
                    DrawingCanvas(drawing: $drawing).accessibilityLabel("Draw on the screenshot with your finger or Apple Pencil").allowsHitTesting(!sending && !sent)
                }.frame(width: width, height: height).clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { canvasSize = CGSize(width: width, height: height) }
                    .onChange(of: geometry.size) { _, _ in
                        let newSize = CGSize(width: width, height: height)
                        if canvasSize.width > 0 {
                            drawing = drawing.transformed(using: CGAffineTransform(scaleX: newSize.width / canvasSize.width, y: newSize.height / canvasSize.height))
                        }
                        canvasSize = newSize
                    }
            }
            HStack {
                Text("Draw to mark the issue.").font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                Button("Clear marks") { drawing = PKDrawing() }.font(.caption).frame(minHeight: 44).disabled(sending || sent)
            }
            TextField("What should the agent change?", text: $instruction, axis: .vertical).lineLimit(2...4)
                .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10)).focused($editing).accessibilityLabel("Instruction for the agent").disabled(sending || sent)
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            if sent {
                Label("Feedback saved to /workspace/inbox.", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Theme.green)
                Button("Done") { dismiss() }.buttonStyle(ActionStyle())
            } else {
                Text("Uploads the marked screenshot and device report. An agent must watch the inbox to pick it up.").font(.caption).foregroundStyle(Theme.muted)
                Button { editing = false; Task { await send() } } label: {
                    Label(sending ? "Uploading…" : "Upload feedback", systemImage: "paperplane").frame(maxWidth: .infinity)
                }.buttonStyle(ActionStyle()).disabled(sending || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).background(Theme.background).navigationTitle("Fix this").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(sending) } }
            .interactiveDismissDisabled(sending)
    }
    private func send() async {
        sending = true; failure = nil
        defer { sending = false }
        do {
            guard canvasSize.width > 0 else { return }
            let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
            let marked = renderer.image { context in
                snapshot.image.draw(in: CGRect(origin: .zero, size: snapshot.image.size))
                context.cgContext.scaleBy(x: snapshot.image.size.width / canvasSize.width, y: snapshot.image.size.height / canvasSize.height)
                drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: snapshot.image.scale).draw(in: CGRect(origin: .zero, size: canvasSize))
            }
            let bytes = try FeedbackEncoder.jpeg(marked)
            var report = snapshot.report
            report.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            report.screenshot = "feedback-\(reportID).jpg"
            let metadata = try JSONEncoder().encode(report)
            let client = try store.api
            try await client.makeInbox(workspace)
            try await client.upload(bytes, path: "/workspace/inbox/\(report.screenshot)", workspace: workspace)
            // JSON is the completion marker: consumers must only watch feedback-*.json.
            try await client.upload(metadata, path: "/workspace/inbox/feedback-\(reportID).json", workspace: workspace)
            sent = true
        } catch { failure = "Feedback wasn't fully uploaded. Your screenshot and instruction are still here; try again." }
    }
}
