import AppKit
import ApplicationServices

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

@main
struct FilePromiseDragProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            fputs("File promise drag verification failed: \(error)\n", stderr)
            if CommandLine.arguments.count == 3 {
                let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                try? JSONSerialization.data(withJSONObject: ["state": "failed", "error": String(describing: error)])
                    .write(to: output.appendingPathComponent("driver-result.json"), options: .atomic)
            }
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 3, CGPreflightPostEventAccess() else {
            throw ProbeFailure("A QA app path, output path, and event posting access are required")
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?["CGSSessionScreenIsLocked"] as? Bool != true else {
            throw ProbeFailure("The console session is locked; actual drag verification requires an unlocked session")
        }
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["FILES_PROMISE_QA_OUTPUT": output.path]
        let running = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        guard running.bundleURL?.standardizedFileURL == appURL else { throw ProbeFailure("Unexpected launched app") }
        defer { running.terminate() }
        try JSONSerialization.data(withJSONObject: ["processID": running.processIdentifier, "app": appURL.path])
            .write(to: output.appendingPathComponent("launch.json"), options: .atomic)
        func wait(_ message: String, until predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                if predicate() { return }
                if running.isTerminated { throw ProbeFailure("QA process terminated: " + message) }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ProbeFailure(message)
        }
        let progress = output.appendingPathComponent("progress.json")
        try await wait("QA window did not become ready") { FileManager.default.fileExists(atPath: progress.path) }
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: progress)) as? [String: Any]
        guard data?["processID"] as? Int32 == running.processIdentifier else { throw ProbeFailure("Unexpected QA process ID") }
        func point(_ key: String) throws -> CGPoint {
            guard let values = data?[key] as? [String: Double], let x = values["x"], let y = values["y"] else {
                throw ProbeFailure("Missing QA coordinates")
            }
            return CGPoint(x: x, y: y)
        }
        let start = try point("source"), end = try point("destination")
        running.activate()
        try await wait("QA app could not be activated") { running.isActive }
        var pressed = false
        func post(_ type: CGEventType, _ point: CGPoint) throws {
            guard running.isActive else { throw ProbeFailure("QA app lost focus") }
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw ProbeFailure("Could not create a drag event")
            }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        defer {
            if pressed {
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        try post(.mouseMoved, start)
        try post(.leftMouseDown, start)
        pressed = true
        for step in 1...24 {
            try await Task.sleep(for: .milliseconds(40))
            let t = CGFloat(step) / 24
            try post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        try await Task.sleep(for: .milliseconds(100))
        try post(.leftMouseUp, end)
        pressed = false
        let report = output.appendingPathComponent("report.json")
        try await wait("File promise did not complete after the drop") { FileManager.default.fileExists(atPath: report.path) }
        print(try String(contentsOf: report, encoding: .utf8))
    }
}
