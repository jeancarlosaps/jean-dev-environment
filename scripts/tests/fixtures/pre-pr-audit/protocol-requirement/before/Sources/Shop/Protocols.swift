import Foundation

public protocol CartServicing {
    func cart() async throws -> Int
}

public protocol PriceFormatting {
    func format(_ value: Int) -> String
}
