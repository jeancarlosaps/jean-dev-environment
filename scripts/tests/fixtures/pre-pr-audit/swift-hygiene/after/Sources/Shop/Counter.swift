import Foundation

public final class Counter: @unchecked Sendable {
    private var value = 0
    public init() {}

    @available(*, deprecated)
    public func legacyIncrement() { value += 1 }
}
