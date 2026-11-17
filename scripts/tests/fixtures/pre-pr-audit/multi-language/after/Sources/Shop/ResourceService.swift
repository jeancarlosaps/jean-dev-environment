import Combine
import Foundation

public final class ResourceService {
    private let client: HTTPClient

    public init(client: HTTPClient) { self.client = client }

    public func removeResource(id: String, version: APIVersion) -> AnyPublisher<Resource, ServiceError> {
        client.data(Endpoint.removeResource(id: id, version: version))
            .mapError(ServiceError.init)
            .acceptStatus(200..<300)
            .map { payload -> Resource? in
                switch version {
                case .v1: return try? JSONDecoder().decode(ResourceV1Response.self, from: payload).resource
                case .v2: return try? JSONDecoder().decode(ResourceV2Response.self, from: payload).data.resource
                }
            }
            .compactMap { $0 }
            .mapError(ServiceError.init)
            .eraseToAnyPublisher()
    }

    @available(*, deprecated, renamed: "removeResource(id:version:)", message: "Remover quando a versão 1 sair")
    public func removeResource(id: String) -> AnyPublisher<Resource, ServiceError> {
        removeResource(id: id, version: .v1)
    }
}
