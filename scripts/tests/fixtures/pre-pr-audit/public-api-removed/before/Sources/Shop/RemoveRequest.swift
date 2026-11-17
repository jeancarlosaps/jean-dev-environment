import Foundation

public struct RemoveRequest: Encodable, Equatable {
    public let id: String
    public let customerId: String?

    public init(id: String) {
        self.id = id
        self.customerId = nil
    }

    public init(legacyId: String, customerId: String) {
        self.id = legacyId
        self.customerId = customerId
    }
}
