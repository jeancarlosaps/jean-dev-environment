import Foundation

public enum Poller {
    public static func wait() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}
