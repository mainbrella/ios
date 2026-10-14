import Foundation

struct ComputeBalance: Decodable {
    let balanceCents: Int
    let availableBalanceCents: Int
    let currency: String
    var formatted: String { (Double(availableBalanceCents) / 100).formatted(.currency(code: "USD")) }
}

struct AppleCreditQuote: Decodable {
    let productId: String
    let appAccountToken: UUID
    let creditCents: Int
    let currency: String
    var formattedCredit: String { (Double(creditCents) / 100).formatted(.currency(code: "USD")) }
}

struct AppleCreditReceipt: Decodable {
    let balance: ComputeBalance
    let creditedCents: Int
    let transactionId: String
}

enum CreditError: LocalizedError {
    case unavailable, unverified, deliveryPending, response(Int, String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Compute credit purchases are currently unavailable. Try again shortly."
        case .unverified: return "The App Store couldn't verify this purchase. No credit has been added."
        case .deliveryPending: return "Your purchase is saved. Check your connection, then tap Check purchases to add its credit."
        case .response(let status, let code):
            if status == 401 { return "Sign in again in Account, then check purchases to add your credit." }
            switch code {
            case "apple_purchase_not_owned": return "This purchase belongs to another Mainbrella account. Sign in to that account to receive its credit."
            case "apple_price_unavailable": return "Compute credit isn't available for your App Store price or region yet."
            case "invalid_apple_transaction": return "The purchase couldn't be verified. Check purchases to try again."
            default: return "Credit couldn't be confirmed. Check purchases to try again; completed purchases won't be charged again."
            }
        }
    }
}

struct BillingClient {
    private struct Failure: Decodable { let error: String }
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    func balance() async throws -> ComputeBalance {
        struct Response: Decodable { let balance: ComputeBalance }
        let response: Response = try await read("billing/balance")
        guard response.balance.currency == "usd" else { throw CreditError.unavailable }
        return response.balance
    }
    func quote(_ product: ComputeProduct) async throws -> AppleCreditQuote {
        let quote: AppleCreditQuote = try await read("billing/apple/config", query: [
            URLQueryItem(name: "storefront", value: product.storefront),
            URLQueryItem(name: "currency", value: product.currency),
            URLQueryItem(name: "priceMilliunits", value: String(product.priceMilliunits)),
        ])
        guard quote.productId == ComputeProduct.id, quote.currency == "usd", quote.creditCents > 0 else { throw CreditError.unavailable }
        return quote
    }
    func complete(_ signedTransaction: String) async throws -> AppleCreditReceipt {
        let receipt: AppleCreditReceipt = try await read("billing/apple/transactions", body: ["signedTransactionInfo": signedTransaction])
        guard receipt.balance.currency == "usd", receipt.creditedCents >= 0 else { throw CreditError.deliveryPending }
        return receipt
    }
    private func read<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: String]? = nil) async throws -> T {
        var url = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 35
        request.setValue("mainbrella_session=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://mainbrella.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CreditError.deliveryPending }
        guard (200..<300).contains(http.statusCode) else {
            throw CreditError.response(http.statusCode, (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
