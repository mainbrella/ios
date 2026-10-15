import SwiftUI

@MainActor final class BuilderPreviewState {
    let controller = PreviewController()
    private var lastURL: URL?
    private var lastRevision: Int?

    func load(url: URL, revision: Int) {
        guard lastURL != url || lastRevision != revision else { return }
        lastURL = url
        lastRevision = revision
        controller.load(url)
    }
}

struct BuilderPreviewView: View {
    let url: URL
    let revision: Int
    let state: BuilderPreviewState
    @ObservedObject private var controller: PreviewController
    private struct LoadIdentity: Equatable { let url: URL; let revision: Int }

    init(url: URL, revision: Int, state: BuilderPreviewState) {
        self.url = url
        self.revision = revision
        self.state = state
        _controller = ObservedObject(wrappedValue: state.controller)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: url.scheme == "https" ? "lock" : "globe").font(.caption).foregroundStyle(Theme.muted).accessibilityHidden(true)
                Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .accessibilityIdentifier("builder-preview-url")
                Spacer(minLength: 0)
                Button { controller.load(url) } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("Reload preview")
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                    .accessibilityLabel("Share preview link")
            }.padding(.leading, 16).padding(.trailing, 4).background(Theme.surface)
            ZStack {
                WebPreview(controller: controller).accessibilityIdentifier("builder-webview")
                if controller.loading {
                    ProgressView("Loading preview…").padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                if let failure = controller.failure {
                    VStack(spacing: 12) {
                        Text(failure).font(.subheadline).multilineTextAlignment(.center)
                        Button("Try again") { controller.load(url) }.buttonStyle(ActionStyle())
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                }
            }
        }
        .task(id: LoadIdentity(url: url, revision: revision)) { state.load(url: url, revision: revision) }
    }
}
