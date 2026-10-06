import Foundation
import ImageIO
import CoreGraphics

// Explicitly invoked development check. Never compiled into the iOS app.
@main struct ProductionSmoke {
    struct Created: Decodable {
        struct Identity: Decodable { let containerId: String; let createdAt: String }
        let containers: [Workspace]
        let creation: Identity
    }
    struct CheckFailure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }
    static func main() async {
        do { try await run() }
        catch {
            let message = (error as? CheckFailure)?.message ?? error.localizedDescription
            print("FAIL: \(message)")
            exit(1)
        }
    }
    static func run() async throws {
        let uiDestination = CommandLine.arguments.contains("--ui") ? try simulatorDestination() : nil
        let envFile = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "../backend/.env"
        let lines = try String(contentsOfFile: envFile, encoding: .utf8).components(separatedBy: .newlines)
        guard let entry = lines.first(where: { $0.hasPrefix("MAINBRELLA_API_KEY=") }) else {
            throw CheckFailure(message: "MAINBRELLA_API_KEY is missing")
        }
        let token = String(entry.dropFirst("MAINBRELLA_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let client = APIClient(baseURL: ServiceURLs.api, token: token)
        let key = "ios-check-" + UUID().uuidString.lowercased()
        let checkpoint = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(key + ".json")
        try JSONSerialization.data(withJSONObject: ["creationKey": key]).write(to: checkpoint)
        print("Creating one temporary Lite workspace. Recovery checkpoint: \(checkpoint.path)")
        let data = try await client.request("containers", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["size": "lite", "catalogId": "node"]), idempotencyKey: key)
        let created = try JSONDecoder().decode(Created.self, from: data)
        guard let workspace = created.containers.first(where: { $0.id == created.creation.containerId && $0.createdAt == created.creation.createdAt }) else {
            throw CheckFailure(message: "Creation identity missing; inspect checkpoint")
        }
        try JSONSerialization.data(withJSONObject: ["creationKey": key, "id": workspace.id, "createdAt": workspace.createdAt]).write(to: checkpoint)
        do {
            try await check(client, workspace: workspace, uiDestination: uiDestination)
        } catch {
            _ = try await client.request("containers", method: "DELETE", workspace: workspace)
            try FileManager.default.removeItem(at: checkpoint)
            print("Temporary workspace stopped after failed check.")
            throw error
        }
        _ = try await client.request("containers", method: "DELETE", workspace: workspace)
        try FileManager.default.removeItem(at: checkpoint)
        print("PASS: production decoding, inbox round trip, execution output, protected preview and revocation. Temporary workspace stopped.")
    }
    static func check(_ client: APIClient, workspace: Workspace, uiDestination: String?) async throws {
        let spaces = try await client.workspaces()
        try require(spaces.contains(workspace), "Workspace decoding failed")
        let id = UUID().uuidString.lowercased()
        let image = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCfAAB//9k=")!
        let message = InboxMessage(version: 1, createdAt: ISO8601DateFormatter().string(from: Date()),
            workspaceID: workspace.id, generation: workspace.createdAt, source: "ios-photo",
            instruction: "Production API smoke test", text: "Clipboard round trip", attachment: "message-\(id).jpg")
        try await client.sendInbox(message, attachment: image, id: id, workspace: workspace)
        let readImage = try await client.request("containers/files", workspace: workspace,
            query: [.init(name: "path", value: "/workspace/inbox/\(message.attachment!)")])
        try require(readImage == image, "Attachment bytes differ")
        let readJSON = try await client.request("containers/files", workspace: workspace,
            query: [.init(name: "path", value: "/workspace/inbox/message-\(id).json")])
        let saved = try JSONDecoder().decode(InboxMessage.self, from: readJSON)
        try require(saved.generation == workspace.createdAt && saved.text == message.text, "Message identity differs")
        let job = try JSONDecoder().decode(Execution.self, from: await client.request("containers/executions", method: "POST", workspace: workspace,
            body: JSONSerialization.data(withJSONObject: ["command": "printf 'ios-check-output'; printf 'ios-check-error' >&2; exit 1", "timeoutMs": 30000]),
            idempotencyKey: "ios-job-" + id))
        // Consume the supported server stream once; never poll execution state.
        _ = try await client.request("containers/executions/\(job.id)/events", workspace: workspace)
        let detail = try await client.execution(job.id, workspace: workspace)
        try require(detail.execution.needsReview && detail.stdout == "ios-check-output" && detail.stderr == "ios-check-error", "Execution output differs")
        _ = try await client.executions(workspace)
        let server = Data("require('http').createServer((req,res)=>res.end('ios-preview-check')).listen(3000,'0.0.0.0');".utf8)
        try await client.upload(server, path: "/tmp/ios-preview-check.cjs", workspace: workspace)
        _ = try await client.request("containers/exec", method: "POST", workspace: workspace,
            body: JSONSerialization.data(withJSONObject: ["command": "nohup node /tmp/ios-preview-check.cjs >/tmp/ios-preview-check.log 2>&1 </dev/null & sleep 1", "timeoutMs": 30000]))
        let grant = try await client.createPreview(workspace, port: 3000)
        guard let url = grant.url else { throw CheckFailure(message: "Missing protected URL") }
        let (page, response) = try await URLSession.shared.data(from: url)
        try require((response as? HTTPURLResponse)?.statusCode == 200 && String(data: page, encoding: .utf8) == "ios-preview-check", "Protected preview failed")
        if let uiDestination {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
            process.arguments = ["-project", "Mainbrella.xcodeproj", "-scheme", "Mainbrella", "-destination", uiDestination,
                "-derivedDataPath", "DerivedData", "-only-testing:MainbrellaUITests/MainbrellaUITests/testProductionWorkflow", "test"]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "TEST_RUNNER_MAINBRELLA_UI_TEST_KEY": client.token,
                "TEST_RUNNER_MAINBRELLA_UI_TEST_WORKSPACE_ID": workspace.id,
                "TEST_RUNNER_MAINBRELLA_UI_TEST_EXECUTION_ID": job.id
            ]) { _, new in new }
            try process.run()
            process.waitUntilExit()
            try require(process.terminationStatus == 0, "Production UI workflow failed")
            struct Listing: Decodable {
                struct Entry: Decodable { let name: String }
                let entries: [Entry]
            }
            let listing = try JSONDecoder().decode(Listing.self, from: await client.request("containers/files/list", workspace: workspace,
                query: [.init(name: "path", value: "/workspace/inbox")]))
            guard let feedback = listing.entries.first(where: { $0.name.hasPrefix("feedback-") && $0.name.hasSuffix(".json") }) else {
                throw CheckFailure(message: "UI feedback was not saved")
            }
            let reportData = try await client.request("containers/files", workspace: workspace,
                query: [.init(name: "path", value: "/workspace/inbox/" + feedback.name)])
            let report = try JSONSerialization.jsonObject(with: reportData) as? [String: Any]
            let metrics = report?["pageMetrics"] as? [String: Double] ?? [:]
            try require((metrics["width"] ?? 0) > 0 && (metrics["pixelRatio"] ?? 0) >= 1, "Device viewport metrics missing")
            guard let filename = report?["screenshot"] as? String else { throw CheckFailure(message: "Screenshot filename missing") }
            let marked = try await client.request("containers/files", workspace: workspace,
                query: [.init(name: "path", value: "/workspace/inbox/" + filename)])
            try require(hasOrangeMarks(marked), "Screenshot annotation pixels missing")
        }
        try await client.revokePreview(workspace, id: grant.id)
        let grants = try await client.previews(workspace)
        try require(!grants.contains { $0.id == grant.id }, "Grant still listed after revocation")
    }
    static func hasOrangeMarks(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var count = 0
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                if bytes[offset] > 180 && bytes[offset + 1] > 70 && bytes[offset + 1] < 210 && bytes[offset + 2] < 100 { count += 1 }
            }
            return count > 20
        }
    }
    static func simulatorDestination() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "-j"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        struct Device: Decodable { let name: String; let udid: String; let state: String }
        struct List: Decodable { let devices: [String: [Device]] }
        let list = try JSONDecoder().decode(List.self, from: data)
        let name = CommandLine.arguments.contains("--ipad") ? "iPad Pro 11-inch (M5)" : "iPhone 17 Pro"
        let matches = list.devices.values.flatMap { $0 }.filter { $0.name == name }
        guard let device = matches.first(where: { $0.state == "Booted" }) ?? matches.first else {
            throw CheckFailure(message: "Install a simulator named \(name) before running --ui")
        }
        return "platform=iOS Simulator,id=\(device.udid)"
    }
}
