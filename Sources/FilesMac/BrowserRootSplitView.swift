import AppKit

/// Side panels keep their user sizes; the browser pane absorbs window resizing.
@MainActor
final class BrowserRootSplitView: NSSplitView, NSSplitViewDelegate {
    private var sidebarWidth: CGFloat = 220
    private var informationWidth: CGFloat = 280
    private var adjusting = false
    private let minimumBrowserWidth: CGFloat = 360

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var hasInformationPane: Bool { arrangedSubviews.count == 3 && !arrangedSubviews[2].isHidden }
    private var visibleSidebarWidth: CGFloat { arrangedSubviews.first?.isHidden == false ? sidebarWidth : 0 }
    private var dividersWidth: CGFloat { CGFloat(max(0, arrangedSubviews.count - 1)) * dividerThickness }
    private var maximumSidebarWidth: CGFloat {
        hasInformationPane ? min(320, max(180, bounds.width - 240 - minimumBrowserWidth - dividersWidth)) : 320
    }
    private var maximumInformationWidth: CGFloat {
        min(420, max(240, bounds.width - min(visibleSidebarWidth, maximumSidebarWidth) - minimumBrowserWidth - dividersWidth))
    }

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        if !adjusting {
            if dividerIndex == 0, arrangedSubviews.first?.isHidden != true {
                sidebarWidth = min(320, max(180, position - bounds.minX))
            } else if dividerIndex == 1, hasInformationPane {
                informationWidth = min(420, max(240, bounds.maxX - position - dividerThickness))
            }
        }
        let previous = adjusting
        adjusting = true
        defer { adjusting = previous }
        super.setPosition(position, ofDividerAt: dividerIndex)
    }

    override func adjustSubviews() {
        guard !adjusting else { super.adjustSubviews(); return }
        adjusting = true
        defer { adjusting = false }
        super.adjustSubviews()
        enforcePanelWidths()
    }

    override func layout() {
        guard !adjusting else { super.layout(); return }
        adjusting = true
        defer { adjusting = false }
        super.layout()
        enforcePanelWidths()
    }

    private func enforcePanelWidths() {
        guard isVertical, arrangedSubviews.count > 1, bounds.width >= 360 else { return }
        if !arrangedSubviews[0].isHidden {
            let width = min(sidebarWidth, maximumSidebarWidth)
            if abs(arrangedSubviews[0].frame.width - width) > 0.5 {
                super.setPosition(bounds.minX + width, ofDividerAt: 0)
            }
        }
        if hasInformationPane {
            let width = min(informationWidth, maximumInformationWidth)
            if abs(arrangedSubviews[2].frame.width - width) > 0.5 {
                super.setPosition(bounds.maxX - width - dividerThickness, ofDividerAt: 1)
            }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard bounds.width >= 360 else { return proposedPosition }
        if dividerIndex == 0, arrangedSubviews.first?.isHidden == false {
            let width = min(maximumSidebarWidth, max(180, proposedPosition - bounds.minX))
            if !adjusting { sidebarWidth = width }
            return bounds.minX + width
        }
        if dividerIndex == 1, hasInformationPane {
            let width = min(maximumInformationWidth, max(240, bounds.maxX - proposedPosition - dividerThickness))
            if !adjusting { informationWidth = width }
            return bounds.maxX - width - dividerThickness
        }
        return proposedPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate position: CGFloat,
                   ofSubviewAt index: Int) -> CGFloat {
        guard bounds.width >= 360 else { return position }
        if index == 0, arrangedSubviews.first?.isHidden == false { return max(position, bounds.minX + 180) }
        if index == 1, hasInformationPane { return max(position, bounds.maxX - maximumInformationWidth - dividerThickness) }
        return position
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate position: CGFloat,
                   ofSubviewAt index: Int) -> CGFloat {
        guard bounds.width >= 360 else { return position }
        if index == 0, arrangedSubviews.first?.isHidden == false { return min(position, bounds.minX + maximumSidebarWidth) }
        if index == 1, hasInformationPane { return min(position, bounds.maxX - 240 - dividerThickness) }
        return position
    }
}
