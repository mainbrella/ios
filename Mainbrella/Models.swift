import Foundation

struct Workspace: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let status: String
    let createdAt: String
    let expiresAt: String
}

struct Execution: Codable, Identifiable {
    let id: String
    let status: String
    let exitCode: Int?
    var running: Bool { !["succeeded", "failed", "canceled", "timed_out", "output_limit", "interrupted"].contains(status) }
    var needsReview: Bool { !running && !["succeeded", "canceled"].contains(status) }
    var statusLabel: String { status.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct ExecutionDetail: Decodable {
    let execution: Execution
    let stdout: String
    let stderr: String
    init(from decoder: Decoder) throws {
        execution = try Execution(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stdout = try values.decode(String.self, forKey: .stdout)
        stderr = try values.decode(String.self, forKey: .stderr)
    }
    private enum CodingKeys: String, CodingKey { case stdout, stderr }
}

struct InboxMessage: Codable {
    let version: Int
    let createdAt: String
    let workspaceID: String
    let generation: String
    let source: String
    let instruction: String
    let text: String
    let attachment: String?
}

struct PreviewGrant: Codable, Identifiable {
    let id: String
    let port: Int
    let createdAt: String
    let expiresAt: Double
    let url: URL?
}

struct PreviewSession: Identifiable {
    let id = UUID()
    let grantID: String
    let workspace: Workspace
    let url: URL
    let expiresAt: Date
}
