import Foundation

public enum TabScrollDirection: Sendable, Equatable {
    case previous, next

    public static func resolve(deltaX: Double, deltaY: Double, reversed: Bool) -> TabScrollDirection? {
        let dominant = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
        guard abs(dominant) >= 0.5 else { return nil }
        let next = (dominant < 0) != reversed
        return next ? .next : .previous
    }
}
