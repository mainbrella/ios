import XCTest
import SwiftUI
@testable import Mainbrella

@MainActor final class ConsoleTests: XCTestCase {
    func testIndependentDraftsAndSelectionWhenClosing() {
        let console = ConsoleTabs()
        let workspace = APIClientTests.workspace
        console.open(workspace)
        let first = console.selected!
        first.draft = "Fix navigation"
        console.open(workspace)
        let second = console.selected!
        second.draft = "Run tests"
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.draft, "Fix navigation")
        console.close(second)
        XCTAssertEqual(console.selectedID, first.id)
        XCTAssertEqual(console.selected?.draft, "Fix navigation")
        first.sending = true
        console.close(first)
        XCTAssertEqual(console.tabs.count, 1)
        console.reset()
        XCTAssertTrue(console.tabs.isEmpty)
        XCTAssertNil(console.selectedID)
    }

    func testRetryRetainsMessageIdentityAndStoppedWorkspaceCannotSend() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        var running = true
        var failUpload = true
        var uploads: [(URL, Data)] = []
        StubProtocol.handler = { request in
            switch (request.httpMethod, request.url!.path) {
            case ("GET", "/containers"):
                var workspace = APIClientTests.workspace
                if !running { workspace = Workspace(id: workspace.id, name: workspace.name, status: "stopped", createdAt: workspace.createdAt, expiresAt: workspace.expiresAt) }
                return (200, try JSONSerialization.data(withJSONObject: ["containers": [JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace))]]))
            case ("GET", "/containers/executions"): return (200, Data("{\"executions\":[]}".utf8))
            case ("GET", "/containers/previews"): return (200, Data("{\"previews\":[]}".utf8))
            case ("POST", "/containers/files/mkdir"): return (200, Data())
            case ("PUT", "/containers/files"):
                uploads.append((request.url!, Self.body(request)))
                return (failUpload ? 503 : 200, Data())
            default: XCTFail("Unexpected request"); return (500, Data())
            }
        }
        let store = AppStore(token: "mb_test", session: session, saveToken: { _ in })
        await store.refresh()
        let tab = ConsoleTab(workspace: APIClientTests.workspace)
        tab.draft = "  Render a screenshot  "
        await tab.send(using: store)
        XCTAssertEqual(tab.draft, "  Render a screenshot  ")
        XCTAssertTrue(tab.feedback!.contains("retry"))
        failUpload = false
        await tab.send(using: store)
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(uploads[0].0, uploads[1].0)
        XCTAssertEqual(uploads[0].1, uploads[1].1)
        XCTAssertEqual(tab.draft, "")
        XCTAssertTrue(tab.feedback!.contains("An agent must read"))
        running = false
        await store.refresh()
        tab.draft = "Keep this draft"
        await tab.send(using: store)
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(tab.draft, "Keep this draft")
    }

    private nonisolated static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func testConsoleLayouts() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            if request.url!.path == "/containers" {
                return (200, try JSONSerialization.data(withJSONObject: ["containers": [JSONSerialization.jsonObject(with: JSONEncoder().encode(APIClientTests.workspace))]]))
            }
            if request.url!.path == "/containers/executions" { return (200, Data("{\"executions\":[]}".utf8)) }
            return (200, Data("{\"previews\":[]}".utf8))
        }
        let store = AppStore(token: "mb_test", session: session, saveToken: { _ in })
        await store.refresh()
        let console = ConsoleTabs()
        console.open(APIClientTests.workspace)
        console.selected?.draft = "Build the account settings page, run the tests, and start a web preview on port 3000."
        console.open(Workspace(id: "other", name: "Android client / notification delivery", status: "running", createdAt: "today", expiresAt: "later"))
        console.selectedID = console.tabs[0].id
        for size in [CGSize(width: 390, height: 844), CGSize(width: 768, height: 1024), CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900)] {
            let host = UIHostingController(rootView: NavigationStack { ConsoleView() }.environmentObject(store).environmentObject(console).preferredColorScheme(.dark))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            let image = UIGraphicsImageRenderer(size: size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Workspace \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
            if size.width == 390 { try image.pngData()!.write(to: URL(fileURLWithPath: "/tmp/mainbrella-console-phone.png")) }
            if size.width == 768 { try image.pngData()!.write(to: URL(fileURLWithPath: "/tmp/mainbrella-console-ipad.png")) }
            window.isHidden = true
        }
    }
}
