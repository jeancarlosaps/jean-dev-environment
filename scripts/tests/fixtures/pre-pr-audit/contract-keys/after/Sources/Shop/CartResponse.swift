import Foundation

public struct CartResponse: Decodable {
    public let orderId: String
    public let total: Int

    enum CodingKeys: String, CodingKey {
        case orderId = "basketId"
        case total
    }
}
