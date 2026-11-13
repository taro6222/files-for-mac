import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

public struct KeyboardShortcut: Codable, Hashable, Sendable {
    public var key: String
    public var modifiers: ShortcutModifiers
    public init(key: String, modifiers: ShortcutModifiers) {
        self.key = Self.normalize(key); self.modifiers = modifiers
    }
    public static func normalize(_ key: String) -> String { key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

public enum ShortcutValidationError: Error, Equatable, Sendable {
    case emptyKey
    case modifierRequired
    case systemReserved
    case conflict(commandID: String)
}

public final class ShortcutPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public let factory: [String: KeyboardShortcut]
    public let knownCommandIDs: Set<String>
    private var overrides: [String: KeyboardShortcut]

    public init(defaults: UserDefaults = .standard, key: String = "keyboardShortcutOverrides",
                factory: [String: KeyboardShortcut], knownCommandIDs: Set<String>? = nil) {
        self.defaults = defaults; self.key = key; self.factory = factory
        self.knownCommandIDs = knownCommandIDs ?? Set(factory.keys)
        overrides = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: KeyboardShortcut].self, from: $0) } ?? [:]
        overrides = overrides.filter { self.knownCommandIDs.contains($0.key) }
    }
    public var effective: [String: KeyboardShortcut] { factory.merging(overrides) { _, override in override } }
    public func shortcut(for commandID: String) -> KeyboardShortcut? { overrides[commandID] ?? factory[commandID] }
    public func set(_ shortcut: KeyboardShortcut, for commandID: String) throws {
        guard knownCommandIDs.contains(commandID) else { return }
        let shortcut = KeyboardShortcut(key: shortcut.key, modifiers: shortcut.modifiers)
        guard !shortcut.key.isEmpty else { throw ShortcutValidationError.emptyKey }
        guard !shortcut.modifiers.isEmpty else { throw ShortcutValidationError.modifierRequired }
        guard !Self.isSystemReserved(shortcut) else { throw ShortcutValidationError.systemReserved }
        if let conflict = effective.first(where: { $0.key != commandID && $0.value == shortcut })?.key {
            throw ShortcutValidationError.conflict(commandID: conflict)
        }
        if shortcut == factory[commandID] { overrides.removeValue(forKey: commandID) }
        else { overrides[commandID] = shortcut }
        persist()
    }
    public func resetAll() { overrides = [:]; persist() }
    private func persist() { defaults.set(try? JSONEncoder().encode(overrides), forKey: key) }
    public static func isSystemReserved(_ shortcut: KeyboardShortcut) -> Bool {
        let m = shortcut.modifiers
        return (shortcut.key == "tab" && m.contains(.command))
            || (shortcut.key == "space" && (m == [.command] || m == [.control]))
            || (shortcut.key == "escape" && m.contains([.command, .option]))
    }
}
