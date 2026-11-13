import AppKit

@MainActor
func fitDetailColumns(
    in table: NSTableView,
    rowCount: Int,
    text: (NSUserInterfaceItemIdentifier, Int) -> String
) {
    let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let header = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    for column in table.tableColumns where !column.isHidden {
        let identifier = column.identifier
        var contentWidth = (column.title as NSString).size(withAttributes: [.font: header]).width
        for row in 0..<rowCount {
            contentWidth = max(contentWidth, (text(identifier, row) as NSString).size(withAttributes: [.font: body]).width)
        }
        let iconAllowance: CGFloat = identifier.rawValue == "name" ? 28 : 0
        column.width = min(720, max(column.minWidth, ceil(contentWidth + iconAllowance + 24)))
    }
}
