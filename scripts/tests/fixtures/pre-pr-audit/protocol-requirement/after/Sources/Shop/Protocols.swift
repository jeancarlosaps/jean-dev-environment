import Foundation

public protocol CartServicing {
    func cart() async throws -> Int
    func clear() async throws
}

public protocol PriceFormatting {
    func format(_ value: Int) -> String
    func currencyCode() -> String
}

public extension PriceFormatting {
    func currencyCode() -> String { "BRL" }
}
