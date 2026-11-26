import AppKit

@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROBE_OUTPUT"]!)
    let tabs = ProcessInfo.processInfo.environment["PROBE_TABS"] == "1"
    let cycles = Int(ProcessInfo.processInfo.environment["PROBE_CYCLES"] ?? "400")!
    var primary: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }
    func window(_ title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 900,height: 600),
            styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.titlebarAppearsTransparent = true
        window.tabbingMode = tabs ? .automatic : .disallowed
        return window
    }
    func report(_ cycle: Int, _ state: String) throws {
        let data: [String:Any] = ["cycle":cycle,"state":state,"pid":ProcessInfo.processInfo.processIdentifier,
                                "tabs":tabs,"os":ProcessInfo.processInfo.operatingSystemVersionString,
                                "releasedSecondaryWindows":cycle,"primaryClass":NSStringFromClass(object_getClass(primary!)!)]
        try JSONSerialization.data(withJSONObject: data,options:[.sortedKeys]).write(to:output.appendingPathComponent("report.json"),options:.atomic)
    }
    func run() async {
        do {
            primary = window("Primary")
            primary.makeKeyAndOrderFront(nil)
            guard cycles >= 40 else { throw NSError(domain:"At least forty cycles required",code:1) }
            for cycle in 1...cycles {
                weak var released: NSWindow?
                try autoreleasepool {
                    let secondary = window("Secondary")
                    released = secondary
                    secondary.makeKeyAndOrderFront(nil)
                    if tabs {
                        primary.addTabbedWindow(secondary,ordered:.above)
                        guard primary.tabbedWindows?.count == 2 else { throw NSError(domain:"Tab did not attach",code:cycle) }
                    } else {
                        guard (primary.tabbedWindows?.count ?? 1) == 1 && (secondary.tabbedWindows?.count ?? 1) == 1 else {
                            throw NSError(domain:"Standalone window joined tabs",code:cycle)
                        }
                    }
                    secondary.contentView?.layoutSubtreeIfNeeded()
                    secondary.displayIfNeeded()
                    secondary.close()
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while released != nil && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(20)) }
                guard released == nil else { throw NSError(domain:"Window retained",code:cycle) }
                try await Task.sleep(for:.milliseconds(50))
                if cycle == 5 || cycle == 40 || cycle == cycles {
                    try report(cycle,"waiting")
                    let checkpointDeadline = ContinuousClock.now + .seconds(45)
                    while !FileManager.default.fileExists(atPath:output.appendingPathComponent("continue-\(cycle)").path) {
                        guard ContinuousClock.now < checkpointDeadline else { throw NSError(domain:"Checkpoint timed out",code:cycle) }
                        try await Task.sleep(for:.milliseconds(20))
                    }
                }
            }
            try report(cycles,"completed")
            primary.close()
            NSApp.terminate(nil)
        } catch {
            try? report(0,"failed: \(error)")
            NSApp.terminate(nil)
        }
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let probe = Probe()
        app.delegate = probe
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(probe) {}
    }
}
