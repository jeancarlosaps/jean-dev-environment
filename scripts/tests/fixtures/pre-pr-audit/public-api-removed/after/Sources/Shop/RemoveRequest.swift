import Foundation

public struct RemoveRequest: Encodable {
    public let id: String
    public let customerId: String?

    public init(id: String) {
        self.id = id
        self.customerId = nil
    }
}
