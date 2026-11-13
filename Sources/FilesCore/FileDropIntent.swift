import Foundation

public struct DropModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let option = DropModifiers(rawValue: 1 << 0)
    public static let command = DropModifiers(rawValue: 1 << 1)
}

public enum FileDropIntent: String, Sendable {
    case copy
    case move

    public static func resolve(modifiers: DropModifiers, sourceAllowsMove: Bool) -> FileDropIntent {
        if modifiers.contains(.option) { return .copy }
        if modifiers.contains(.command), sourceAllowsMove { return .move }
        return .copy
    }
}
