import AppKit
import Foundation
import Darwin

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); Darwin.exit(1)
}

@MainActor
func measure(initialScrollFrame: Bool, finalWidth: CGFloat = 844, repeats: Int = 12) -> [String: Double] {
    let target = NSRect(x: 0, y: 0, width: 844, height: 130)
    let scroll = NSScrollView(frame: initialScrollFrame ? target : .zero)
    let text = NSTextView(frame: target)
    text.isEditable = false; text.isSelectable = true
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.containerSize = NSSize(width: 844, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
    scroll.frame = NSRect(x: 0, y: 0, width: finalWidth, height: 130); scroll.layoutSubtreeIfNeeded()
    text.string = "Previous original restored\n" + "/Users/runner/work/_temp/files-ui-verification.example/en-light/.files-archive-edit-" + String(repeating: "ABCDEF-", count: repeats) + "/candidate.zip"
    guard let container = text.textContainer, let layout = text.layoutManager else { fail("Text layout unavailable") }
    layout.ensureLayout(for: container)
    return ["documentWidth": text.bounds.width, "viewportWidth": scroll.contentSize.width,
            "containerWidth": container.containerSize.width, "usedWidth": layout.usedRect(for: container).width,
            "usedHeight": layout.usedRect(for: container).height, "documentHeight": text.bounds.height]
}
@main struct LayoutProbe {
    @MainActor static func main() throws {
        let result = ["zeroInitialScroll": measure(initialScrollFrame: false), "sizedInitialScroll": measure(initialScrollFrame: true), "sizedMinimum": measure(initialScrollFrame: true, finalWidth: 764), "longContent": measure(initialScrollFrame: true, finalWidth: 764, repeats: 120)]
        guard let original = result["zeroInitialScroll"], original["documentWidth"]! > original["viewportWidth"]! else { fail("Original overflow was not reproduced") }
        for name in ["sizedInitialScroll", "sizedMinimum", "longContent"] {
        let item = result[name]!
        guard item["documentWidth"]! <= item["viewportWidth"]! + 1,
        item["containerWidth"]! <= item["viewportWidth"]! + 1,
        item["usedWidth"]! <= item["viewportWidth"]! + 1, item["documentHeight"]! >= item["usedHeight"]!, item["usedHeight"]! > 0 else { fail("Text overflow: " + name) }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))

    }
}
