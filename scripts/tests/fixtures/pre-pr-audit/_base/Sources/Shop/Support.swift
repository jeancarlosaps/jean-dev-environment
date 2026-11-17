import Combine
import Foundation

public enum APIVersion { case v1, v2 }

public struct Resource: Decodable { public let id: String }

public struct ServiceError: Error {
    public init(_ error: Error) {}
}

public protocol HTTPClient {
    func data(_ endpoint: Endpoint) -> AnyPublisher<Data, Error>
}

public enum Endpoint {
    case removeResourceV1(id: String)
    case removeResourceV2(id: String)
    case removeResource(id: String, version: APIVersion)
}

extension Publisher where Output == Data {
    func acceptStatus(_ range: Range<Int>) -> Self { self }
}
