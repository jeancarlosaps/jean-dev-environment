import Foundation

public final class CartStore {
    public init() {}

    public func removeItem(id: String) {}
    public func removeAll() {}
    func removeExpired() {}
}

public struct RemoveItemResponse: Decodable { public let ok: Bool }

public extension CartStore {
    func delResource(id: String) {}
}

public struct DelResourceResponse: Decodable { public let ok: Bool }
