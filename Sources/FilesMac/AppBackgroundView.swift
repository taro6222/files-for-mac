import AppKit

final class AppBackgroundView: NSView {
    private(set) var image: NSImage?

    @discardableResult
    func setImage(at path: String?) -> Bool {
        image = path.flatMap { NSImage(contentsOfFile: $0) }
        needsDisplay = true
        return path == nil || image != nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0.86 : 0.58
        NSColor.controlBackgroundColor.withAlphaComponent(alpha).setFill(); bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
