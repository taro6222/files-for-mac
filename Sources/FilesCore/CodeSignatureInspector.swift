import Foundation

public struct CodeSignatureReport: Equatable, Sendable {
    public enum State: String, Sendable { case valid, invalid, unsigned }
    public let state: State
    public let identifier: String?
    public let teamIdentifier: String?
    public let authorities: [String]
    public let format: String?
    public let diagnostic: String?

    public init(state: State, identifier: String?, teamIdentifier: String?, authorities: [String], format: String?, diagnostic: String?) {
        self.state = state; self.identifier = identifier; self.teamIdentifier = teamIdentifier
        self.authorities = authorities; self.format = format; self.diagnostic = diagnostic
    }
}

public enum CodeSignatureInspector {
    public static func inspect(_ url: URL) async -> CodeSignatureReport {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return CodeSignatureReport(state: .invalid, identifier: nil, teamIdentifier: nil, authorities: [], format: nil, diagnostic: "File not found")
            }
            let details = run(["-dvv", "--", url.path])
            let verification = run(["--verify", "--deep", "--strict", "--verbose=2", "--", url.path])
            let metadata = parse(details.output)
            let combined = (details.output + "\n" + verification.output).lowercased()
            let state: CodeSignatureReport.State
            if verification.status == 0 { state = .valid }
            else if combined.contains("not signed at all") || combined.contains("code object is not signed") { state = .unsigned }
            else { state = .invalid }
            return CodeSignatureReport(state: state, identifier: metadata.identifier, teamIdentifier: metadata.teamIdentifier,
                                       authorities: metadata.authorities, format: metadata.format,
                                       diagnostic: verification.status == 0 ? nil : verification.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    public static func parse(_ output: String) -> (identifier: String?, teamIdentifier: String?, authorities: [String], format: String?) {
        var identifier: String?, team: String?, authorities: [String] = [], format: String?
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Identifier=") { identifier = String(line.dropFirst("Identifier=".count)) }
            else if line.hasPrefix("TeamIdentifier=") { team = String(line.dropFirst("TeamIdentifier=".count)); if team == "not set" { team = nil } }
            else if line.hasPrefix("Authority=") { authorities.append(String(line.dropFirst("Authority=".count))) }
            else if line.hasPrefix("Format=") { format = String(line.dropFirst("Format=".count)) }
        }
        return (identifier, team, authorities, format)
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe
        do { try process.run(); process.waitUntilExit() }
        catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data.prefix(256 * 1024), as: UTF8.self))
    }
}
