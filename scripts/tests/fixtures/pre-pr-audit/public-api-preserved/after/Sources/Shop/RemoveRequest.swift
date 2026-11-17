import Foundation

public struct RemoveRequest: Encodable, Equatable {
    public let id: String
    public let customerId: String?

    public init(id: String) {
        self.id = id
        self.customerId = nil
    }

    // MARK: - Deprecated

    @available(*, deprecated, renamed: "init(id:)", message: "Remover quando a versão 1 sair")
    public init(legacyId: String, customerId: String) {
        self.id = legacyId
        self.customerId = customerId
    }
}
