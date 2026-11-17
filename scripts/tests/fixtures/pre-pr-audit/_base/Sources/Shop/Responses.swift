import Foundation

struct ResourceV1Response: Decodable { let resource: Resource }
struct ResourceV2Response: Decodable {
    struct Payload: Decodable { let resource: Resource }
    let data: Payload
    func validated() throws -> ResourceV2Response { self }
}
