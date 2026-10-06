import Foundation

struct Workspace: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let status: String
    let createdAt: String
    let expiresAt: String
    static let demo = Workspace(id: "demo", name: "mainbrella/web", status: "running", createdAt: "2026-10-05T12:00:00.000Z", expiresAt: "2026-10-05T13:00:00.000Z")
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
    let url: URL?
    let expiresAt: Date?
}

struct Approval: Identifiable {
    let id = UUID()
    let title: String
    let agent: String
    let symbol: String
    let sensitive: Bool
    static var examples: [Approval] { [
        Approval(title: "Allow outbound access to api.stripe.com?", agent: "Payments Agent · 2 min ago", symbol: "link", sensitive: false),
        Approval(title: "Use STRIPE_TEST_KEY for test checkout?", agent: "Backend Agent · 28 min ago", symbol: "key", sensitive: true)
    ] }
}
