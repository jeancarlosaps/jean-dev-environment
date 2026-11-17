import Combine
import Foundation

public final class ResourceService {
    private let client: HTTPClient

    public init(client: HTTPClient) { self.client = client }

    public func removeResource(id: String, version: APIVersion) -> AnyPublisher<Resource, ServiceError> {
        switch version {
        case .v1:
            return client.data(Endpoint.removeResourceV1(id: id))
                .mapError(ServiceError.init)
                .acceptStatus(200..<300)
                .decode(type: ResourceV1Response.self, decoder: JSONDecoder())
                .map { $0.resource }
                .mapError(ServiceError.init)
                .eraseToAnyPublisher()
        case .v2:
            return client.data(Endpoint.removeResourceV2(id: id))
                .mapError(ServiceError.init)
                .acceptStatus(200..<300)
                .decode(type: ResourceV2Response.self, decoder: JSONDecoder())
                .map { $0.data.resource }
                .mapError(ServiceError.init)
                .eraseToAnyPublisher()
        }
    }

    @available(*, deprecated, renamed: "removeResource(id:version:)", message: "Remover quando a versão 1 sair")
    public func removeResource(id: String) -> AnyPublisher<Resource, ServiceError> {
        removeResource(id: id, version: .v1)
    }
}
