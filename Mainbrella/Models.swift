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
    let workspace: Workspace
    let url: URL
    let expiresAt: Date
}
