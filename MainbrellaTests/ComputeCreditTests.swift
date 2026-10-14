import XCTest
import StoreKit
import StoreKitTest
@testable import Mainbrella

@MainActor private final class TestComputeStorefront: ComputeStorefront {
    let accountToken = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    var result = ComputePurchaseResult.cancelled
    var pending: [ComputeTransaction] = []
    var onPurchase: (() async -> Void)?
    func loadProduct() async throws -> ComputeProduct {
        ComputeProduct(displayPrice: "$4.99", priceMilliunits: 4990, currency: "USD", storefront: "USA")
    }
    func purchase(accountToken: UUID) async throws -> ComputePurchaseResult {
        XCTAssertEqual(accountToken, self.accountToken)
        await onPurchase?()
        return result
    }
    func unfinished() async -> [ComputeTransaction] { pending }
    func updates(_ receive: @escaping @MainActor (ComputeTransaction) async -> Void) async {}
}

@MainActor final class ComputeCreditTests: XCTestCase {
    private var session: URLSession!
    private var client: BillingClient!
    private var shop: TestComputeStorefront!
    private var writes = 0
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
        client = BillingClient(baseURL: URL(string: "http://localhost:8787")!, token: "account-session", session: session)
        shop = TestComputeStorefront()
        StubProtocol.handler = { [self] request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "mainbrella_session=account-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://mainbrella.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            switch request.url!.path {
            case "/billing/balance": return (200, Data("{\"balance\":{\"balanceCents\":0,\"availableBalanceCents\":0,\"currency\":\"usd\"}}".utf8))
            case "/billing/apple/config":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "priceMilliunits" }?.value, "4990")
                XCTAssertEqual(query.first { $0.name == "storefront" }?.value, "USA")
                XCTAssertEqual(query.first { $0.name == "currency" }?.value, "USD")
                return (200, Data("{\"productId\":\"MAINBRELLA_FIVE\",\"appAccountToken\":\"11111111-1111-4111-8111-111111111111\",\"creditCents\":349,\"currency\":\"usd\"}".utf8))
            case "/billing/apple/transactions":
                writes += 1
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: String]
                XCTAssertEqual(body, ["signedTransactionInfo": "verified-jws"])
                return (200, Self.receipt)
            default: XCTFail("Unexpected billing request"); return (404, Data())
            }
        }
    }
    override func tearDown() { session.invalidateAndCancel(); StubProtocol.handler = nil; StubProtocol.responseHeaders = nil }
    private static var receipt: Data {
        Data("{\"balance\":{\"balanceCents\":349,\"availableBalanceCents\":349,\"currency\":\"usd\"},\"creditedCents\":349,\"transactionId\":\"123\"}".utf8)
    }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return data
    }
    func testPurchaseUsesBackendNetQuoteAndFinishesAfterDelivery() async {
        let store = ComputeCreditStore(storefront: shop)
        await store.run(client)
        XCTAssertEqual(store.quote?.creditCents, 349)
        XCTAssertEqual(store.product?.displayPrice, "$4.99")
        var finished = false
        shop.result = .purchased(ComputeTransaction(id: "123", accountToken: shop.accountToken, signed: "verified-jws", finish: { [self] in
            XCTAssertEqual(writes, 1); finished = true
        }))
        await store.purchase()
        XCTAssertTrue(finished)
        XCTAssertEqual(store.balance?.availableBalanceCents, 349)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.busy)
    }
    func testLostDeliveryRemainsUnfinishedAndRetriesSameTransaction() async {
        let store = ComputeCreditStore(storefront: shop)
        await store.run(client)
        var finished = 0, attempts: [Data] = []
        let transaction = ComputeTransaction(id: "123", accountToken: shop.accountToken, signed: "verified-jws", finish: { finished += 1 })
        shop.result = .purchased(transaction)
        let original = StubProtocol.handler!
        StubProtocol.handler = { request in
            if request.url?.path == "/billing/apple/transactions" {
                attempts.append(Self.body(request))
                if attempts.count == 1 { throw URLError(.networkConnectionLost) }
            }
            return try original(request)
        }
        await store.purchase()
        XCTAssertEqual(finished, 0)
        XCTAssertNotNil(store.error)
        shop.pending = [transaction]
        await store.refresh()
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], attempts[1])
        XCTAssertEqual(store.balance?.availableBalanceCents, 349)
    }
    func testCancellationAndPendingApprovalNeverDeliverCredit() async {
        let store = ComputeCreditStore(storefront: shop)
        await store.run(client)
        await store.purchase()
        XCTAssertNil(store.error); XCTAssertNil(store.message)
        shop.result = .pending
        await store.purchase()
        XCTAssertTrue(store.message?.contains("approval") == true)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.balance?.availableBalanceCents, 0)
    }
    func testUnfinishedPurchaseFromAnotherAccountIsNeverClaimedOrFinished() async {
        shop.pending = [ComputeTransaction(id: "123", accountToken: UUID(), signed: "foreign", finish: { XCTFail("Foreign purchase must remain unfinished") })]
        let store = ComputeCreditStore(storefront: shop)
        await store.run(client)
        XCTAssertEqual(writes, 0)
    }
    func testAccountChangeDuringStoreSheetDoesNotDeliverOrFinish() async {
        let store = ComputeCreditStore(storefront: shop)
        await store.run(client)
        shop.result = .purchased(ComputeTransaction(id: "123", accountToken: shop.accountToken, signed: "verified-jws", finish: { XCTFail("Keep purchase for its original account") }))
        shop.onPurchase = { store.reset() }
        await store.purchase()
        XCTAssertEqual(writes, 0); XCTAssertNil(store.balance); XCTAssertFalse(store.busy)
    }
    func testRealStoreKitConfigurationLoadsAndBindsPurchaseToAccount() async throws {
        let testSession = try SKTestSession(configurationFileNamed: "Mainbrella")
        testSession.disableDialogs = true
        testSession.clearTransactions()
        defer { testSession.clearTransactions() }
        let storefront = StoreKitComputeStorefront()
        let product = try await storefront.loadProduct()
        XCTAssertEqual(product.priceMilliunits, 4990)
        XCTAssertEqual(product.currency, "USD")
        XCTAssertEqual(product.storefront, "USA")
        let result = try await storefront.purchase(accountToken: shop.accountToken)
        guard case .purchased(let transaction) = result else { return XCTFail("Expected a verified local StoreKit purchase") }
        XCTAssertEqual(transaction.accountToken, shop.accountToken)
        let payload = transaction.signed.split(separator: ".")[1]
        var encoded = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: encoded))) as! [String: Any]
        XCTAssertEqual(json["productId"] as? String, "MAINBRELLA_FIVE")
        XCTAssertEqual(json["environment"] as? String, "Xcode")
        XCTAssertEqual(json["price"] as? Int, 4990)
        XCTAssertEqual(json["bundleId"] as? String, "com.mainbrella.ios")
        await transaction.finish()
    }
}
