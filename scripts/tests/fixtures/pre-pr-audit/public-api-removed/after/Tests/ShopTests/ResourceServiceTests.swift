import XCTest
@testable import Shop

final class ResourceServiceTests: XCTestCase {
    func testBehavior() {
        XCTAssertNotNil(Endpoint.removeResource(id: "1", version: .v2))
    }
}
