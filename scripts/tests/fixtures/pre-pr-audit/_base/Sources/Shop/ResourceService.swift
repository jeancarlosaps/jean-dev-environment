import Combine
import Foundation

public final class ResourceService {
    private let client: HTTPClient

    public init(client: HTTPClient) { self.client = client }

    public func removeResource(id: String) -> AnyPublisher<Resource, ServiceError> {
        client.data(Endpoint.removeResourceV1(id: id))
            .mapError(ServiceError.init)
            .acceptStatus(200..<300)
            .decode(type: ResourceV1Response.self, decoder: JSONDecoder())
            .map { $0.resource }
            .mapError(ServiceError.init)
            .eraseToAnyPublisher()
    }
}
