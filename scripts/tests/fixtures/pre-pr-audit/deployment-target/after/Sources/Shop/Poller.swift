import Foundation

public enum Poller {
    public static func wait() async throws {
        // antes: Task.sleep(for:) não existe no iOS 15
        if #available(iOS 16, macOS 13, *) {
            try await Task.sleep(for: .milliseconds(200))
        } else {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
