import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

private final class FrameTimes: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: [(received: Double, presented: Double)] = []
    private var statuses: [String: Int] = [:]

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary]
        let status = (attachments?.first?[SCStreamFrameInfo.status.rawValue] as? NSNumber)?.intValue
        lock.withLock { statuses[status.map(String.init) ?? "missing", default: 0] += 1 }
        guard status == SCFrameStatus.complete.rawValue else { return }
        let timestamp = sample.presentationTimeStamp.seconds
        guard timestamp.isFinite else { return }
        let received = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        lock.withLock { timestamps.append((received, timestamp)) }
    }

    func snapshot() -> [(received: Double, presented: Double)] { lock.withLock { timestamps } }
    func frameStatuses() -> [String: Int] { lock.withLock { statuses } }
}

@main struct ScrollWindowCapture {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[1]),
              CGPreflightScreenCaptureAccess() else {
            fputs("Usage: scroll-window <app pid> <app report> <output report> (requires Screen Recording access)\n", stderr)
            exit(2)
        }
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let clock = ContinuousClock()
        let windowDeadline = clock.now + .seconds(8)
        var window: SCWindow?
        while window == nil && clock.now < windowDeadline {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            window = content.windows.first { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            if window == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let window else { throw CocoaError(.fileReadNoSuchFile) }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: nil)
        let frames = FrameTimes()
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "scroll-frame-times"))
        try await stream.startCapture()
        let deadline = clock.now + .seconds(35)
        while !FileManager.default.fileExists(atPath: reportURL.path) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        do {
            try await stream.stopCapture()
        } catch let error as NSError where error.domain == SCStreamErrorDomain
            && error.code == SCStreamError.Code.attemptToStopStreamState.rawValue {
            // The test window can close as soon as the app publishes its report.
        }
        let report = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: reportURL))
        guard let start = report["scrollStartedUptimeSeconds"], let end = report["scrollEndedUptimeSeconds"],
              end > start else { throw CocoaError(.fileReadCorruptFile) }
        let captured = frames.snapshot()
        let timestamps = captured.filter { (start...end).contains($0.received) }.map(\.presented).sorted()
        let intervals = zip(timestamps, timestamps.dropFirst()).map { ($1 - $0) * 1000 }.filter { $0 > 0 }
        guard intervals.count >= 2 else {
            fputs("Insufficient frame samples during scroll (\(captured.count) complete, statuses: \(frames.frameStatuses())).\n", stderr)
            exit(1)
        }
        let ordered = intervals.sorted()
        let p95 = ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1]
        let result: [String: Double] = [
            "capturedFrames": Double(timestamps.count),
            "scrollDurationSeconds": end - start,
            "displayRefreshHz": CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0,
            "p95IntervalMilliseconds": p95,
            "maximumIntervalMilliseconds": ordered[ordered.count - 1],
            "intervalsOver25ms": Double(intervals.filter { $0 > 25 }.count),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: resultURL, options: .atomic)
    }
}
