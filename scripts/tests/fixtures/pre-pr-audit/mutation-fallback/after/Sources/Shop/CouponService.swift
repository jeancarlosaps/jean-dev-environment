import Foundation

public struct Cart { public let total: Int }

public protocol CouponClient {
    func applyCouponV1(_ code: String) async throws -> Cart
    func applyCouponV2(_ code: String) async throws -> Cart
    func fetchCartV1() async throws -> Cart
    func fetchCartV2() async throws -> Cart
}

public final class CouponService {
    private let client: CouponClient
    public init(client: CouponClient) { self.client = client }

    public func applyCoupon(code: String) async throws -> Cart {
        do {
            return try await client.applyCouponV2(code)
        } catch {
            return try await client.applyCouponV1(code)
        }
    }

    public func fetchCart() async throws -> Cart {
        do {
            return try await client.fetchCartV2()
        } catch {
            return try await client.fetchCartV1()
        }
    }
}
