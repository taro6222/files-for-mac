import Foundation

public struct DiagnosticArtifacts: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilesMac", isDirectory: true)
    }
    public var logDirectory: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var logFile: URL { logDirectory.appendingPathComponent("FilesMac.log") }
    public var settingsSnapshot: URL { root.appendingPathComponent("settings.json") }

    @discardableResult public func append(event: String, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let safe = event.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let data = Data("\(formatter.string(from: date)) \(safe)\n".utf8)
        if FileManager.default.fileExists(atPath: logFile.path) {
            let handle = try FileHandle(forWritingTo: logFile)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else {
            try data.write(to: logFile, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
        return logFile
    }

    @discardableResult public func writeSettingsSnapshot(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: settingsSnapshot, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsSnapshot.path)
        return settingsSnapshot
    }
}
