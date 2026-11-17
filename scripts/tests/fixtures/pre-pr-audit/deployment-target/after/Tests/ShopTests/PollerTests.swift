import XCTest
@testable import Shop

final class PollerTests: XCTestCase {
    func testWait() async throws {
        try await Task.sleep(for: .milliseconds(200))
        try await Poller.wait()
    }
}
