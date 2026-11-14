import AppKit
import FilesCore

final class AppBackgroundView: NSView {
    private(set) var image: NSImage?
    private var fit: AppBackgroundFit = .fill
    private var opacity: CGFloat = 1
    private var horizontal: AppBackgroundHorizontalAlignment = .center
    private var vertical: AppBackgroundVerticalAlignment = .center

    func setPresentation(fit: AppBackgroundFit, opacity: Double,
                         horizontal: AppBackgroundHorizontalAlignment, vertical: AppBackgroundVerticalAlignment) {
        self.fit = fit; self.opacity = CGFloat(min(1, max(0, opacity)))
        self.horizontal = horizontal; self.vertical = vertical; needsDisplay = true
    }

    @discardableResult
    func setImage(at path: String?) -> Bool {
        image = path.flatMap { NSImage(contentsOfFile: $0) }
        needsDisplay = true
        return path == nil || image != nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let size: NSSize
        if fit == .stretch { size = bounds.size }
        else {
            let widthScale = bounds.width / image.size.width, heightScale = bounds.height / image.size.height
            let scale = fit == .fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
            size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        let x: CGFloat = horizontal == .leading ? bounds.minX : (horizontal == .trailing ? bounds.maxX - size.width : bounds.midX - size.width / 2)
        let y: CGFloat = vertical == .bottom ? bounds.minY : (vertical == .top ? bounds.maxY - size.height : bounds.midY - size.height / 2)
        image.draw(in: NSRect(origin: NSPoint(x: x, y: y), size: size), from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0.86 : 0.58
        NSColor.controlBackgroundColor.withAlphaComponent(alpha).setFill(); bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
