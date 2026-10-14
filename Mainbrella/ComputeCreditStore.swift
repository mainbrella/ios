import StoreKit
import SwiftUI

struct ComputeProduct {
    static let id = "MAINBRELLA_FIVE"
    let displayPrice: String
    let priceMilliunits: Int
    let currency: String
    let storefront: String
}

struct ComputeTransaction {
    let id: String
    let accountToken: UUID?
    let signed: String
    let finish: () async -> Void
}

enum ComputePurchaseResult { case purchased(ComputeTransaction), pending, cancelled }

@MainActor protocol ComputeStorefront {
    func loadProduct() async throws -> ComputeProduct
    func purchase(accountToken: UUID) async throws -> ComputePurchaseResult
    func unfinished() async -> [ComputeTransaction]
    func updates(_ receive: @escaping @MainActor (ComputeTransaction) async -> Void) async
}

@MainActor final class StoreKitComputeStorefront: ComputeStorefront {
    private var product: Product?
    func loadProduct() async throws -> ComputeProduct {
        guard let product = try await Product.products(for: [ComputeProduct.id]).first,
              product.type == .consumable, let storefront = await Storefront.current else { throw CreditError.unavailable }
        self.product = product
        let milliunits = product.price * 1000
        let value = NSDecimalNumber(decimal: milliunits)
        guard value.intValue > 0, Decimal(value.intValue) == milliunits else { throw CreditError.unavailable }
        return ComputeProduct(displayPrice: product.displayPrice, priceMilliunits: value.intValue,
                              currency: product.priceFormatStyle.currencyCode, storefront: storefront.countryCode)
    }
    func purchase(accountToken: UUID) async throws -> ComputePurchaseResult {
        guard let product else { throw CreditError.unavailable }
        switch try await product.purchase(options: [.appAccountToken(accountToken), .quantity(1)]) {
        case .success(let result):
            guard let transaction = Self.verified(result) else { throw CreditError.unverified }
            return .purchased(transaction)
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw CreditError.unavailable
        }
    }
    func unfinished() async -> [ComputeTransaction] {
        var transactions: [ComputeTransaction] = []
        for await result in StoreKit.Transaction.unfinished {
            if let transaction = Self.verified(result) { transactions.append(transaction) }
        }
        return transactions
    }
    func updates(_ receive: @escaping @MainActor (ComputeTransaction) async -> Void) async {
        for await result in StoreKit.Transaction.updates {
            if Task.isCancelled { return }
            if let transaction = Self.verified(result) { await receive(transaction) }
        }
    }
    private static func verified(_ result: VerificationResult<StoreKit.Transaction>) -> ComputeTransaction? {
        guard case .verified(let transaction) = result, transaction.productID == ComputeProduct.id else { return nil }
        return ComputeTransaction(id: String(transaction.id), accountToken: transaction.appAccountToken,
                                  signed: result.jwsRepresentation, finish: { await transaction.finish() })
    }
}

@MainActor final class ComputeCreditStore: ObservableObject {
    @Published private(set) var product: ComputeProduct?
    @Published private(set) var quote: AppleCreditQuote?
    @Published private(set) var balance: ComputeBalance?
    @Published private(set) var loading = false
    @Published private(set) var purchasing = false
    @Published private(set) var checking = false
    @Published private(set) var availabilityError: String?
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    private let storefront: ComputeStorefront
    private var client: BillingClient?
    private var generation = UUID()
    private var deliveries: Set<String> = []
    var busy: Bool { purchasing || checking || !deliveries.isEmpty }
    var canPurchase: Bool { product != nil && quote != nil && !loading && !busy }

    init(storefront: ComputeStorefront? = nil) { self.storefront = storefront ?? StoreKitComputeStorefront() }
    func reset() {
        generation = UUID(); client = nil; product = nil; quote = nil; balance = nil
        loading = false; purchasing = false; checking = false; deliveries = []
        availabilityError = nil; error = nil; message = nil
    }
    func run(_ client: BillingClient) async {
        reset(); self.client = client
        let generation = self.generation
        // Register the update listener at launch, including Ask to Buy approvals.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await self.storefront.updates { transaction in
                    guard generation == self.generation else { return }
                    await self.deliver(transaction)
                }
            }
            group.addTask { @MainActor in await self.refresh() }
            await group.waitForAll()
        }
    }
    func refresh() async {
        guard let client, !loading else { return }
        let generation = self.generation
        loading = true
        defer { if generation == self.generation { loading = false } }
        // Balance and store availability are independent: a store outage must
        // not hide credit that the account already has.
        do {
            let balance = try await client.balance()
            guard generation == self.generation, !Task.isCancelled else { return }
            self.balance = balance
        } catch { /* Keep the last known balance when a refresh is unavailable. */ }
        do {
            let product = try await storefront.loadProduct()
            let quote = try await client.quote(product)
            guard generation == self.generation, !Task.isCancelled else { return }
            self.product = product; self.quote = quote; availabilityError = nil
            await checkPurchases()
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            product = nil; quote = nil
            // Configuration failures are not failed purchases. Only show them
            // in the funding flow, without suggesting existing credit is invalid.
            switch error {
            case CreditError.response(401, _):
                availabilityError = "Sign in again in Account to add funds."
            case CreditError.response(_, "apple_price_unavailable"):
                availabilityError = error.localizedDescription
            default:
                availabilityError = CreditError.unavailable.localizedDescription
            }
        }
    }
    func purchase() async {
        guard canPurchase, let quote else { return }
        let generation = self.generation
        purchasing = true; error = nil; message = nil
        defer { if generation == self.generation { purchasing = false } }
        do {
            let result = try await storefront.purchase(accountToken: quote.appAccountToken)
            guard generation == self.generation else { return }
            switch result {
            case .purchased(let transaction): await deliver(transaction)
            case .pending: message = "Awaiting App Store approval. Credit will be added after the purchase is approved."
            case .cancelled: break
            }
        } catch {
            guard generation == self.generation else { return }
            self.error = (error as? CreditError)?.localizedDescription ?? CreditError.unavailable.localizedDescription
        }
    }
    func checkPurchases() async {
        guard !checking, quote != nil else { return }
        let generation = self.generation
        checking = true
        defer { if generation == self.generation { checking = false } }
        for transaction in await storefront.unfinished() {
            guard generation == self.generation, !Task.isCancelled else { return }
            await deliver(transaction)
        }
    }
    private func deliver(_ transaction: ComputeTransaction) async {
        guard let client, let quote, transaction.accountToken == quote.appAccountToken,
              !deliveries.contains(transaction.id) else { return }
        let generation = self.generation
        deliveries.insert(transaction.id)
        defer { if generation == self.generation { deliveries.remove(transaction.id) } }
        do {
            let receipt = try await client.complete(transaction.signed)
            guard receipt.transactionId == transaction.id else { throw CreditError.deliveryPending }
            // Backend delivery precedes StoreKit finish. Lost responses remain
            // unfinished and can safely retry after restart or sign-in.
            guard generation == self.generation else { return }
            await transaction.finish()
            guard generation == self.generation else { return }
            balance = receipt.balance; error = nil
            message = receipt.creditedCents > 0
                ? "\((Double(receipt.creditedCents) / 100).formatted(.currency(code: "USD"))) compute credit added."
                : "This purchase was refunded. Your balance is up to date."
        } catch {
            guard generation == self.generation else { return }
            self.error = (error as? CreditError)?.localizedDescription ?? CreditError.deliveryPending.localizedDescription
        }
    }
}
