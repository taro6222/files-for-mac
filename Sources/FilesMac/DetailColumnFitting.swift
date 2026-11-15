import AppKit
import FilesCore

@MainActor
final class FolderSizeCell: NSTableCellView {
    private static let reuseID = NSUserInterfaceItemIdentifier("FolderSizeCell")
    private let button = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var onRequest: (() -> Void)?

    static func view(in table: NSTableView, item: FileItem, model: BrowserModel,
                     preferences: BrowserPreferences, activate: (() -> Void)? = nil) -> FolderSizeCell {
        let cell = (table.makeView(withIdentifier: reuseID, owner: nil) as? FolderSizeCell) ?? FolderSizeCell()
        let status = model.requestedDirectorySize(of: item)
        let automatic = preferences.calculateFolderSizes
        cell.configure(item: item, status: status, text: text(for: item, model: model, preferences: preferences),
                       canRequest: !automatic && !model.isLoading && !model.wasCancelled) { [weak model] in
            activate?()
            model?.requestDirectorySize(of: item)
        }
        return cell
    }

    static func text(for item: FileItem, model: BrowserModel, preferences: BrowserPreferences) -> String {
        switch model.requestedDirectorySize(of: item) {
        case .available(let bytes): return formatByteCount(bytes, unit: preferences.sizeUnit)
        case .calculating: return L("계산 중…", "Calculating…")
        case .unavailable: return L("다시 조회", "Retry Size")
        case nil:
            if preferences.calculateFolderSizes {
                return model.directorySize(of: item).map { formatByteCount($0, unit: preferences.sizeUnit) } ?? "—"
            }
            return model.isLoading || model.wasCancelled ? "—" : L("크기 보기", "View Size")
        }
    }

    private init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.target = self
        button.action = #selector(requestSize(_:))
        addSubview(statusLabel)
        addSubview(button)
        for view in [statusLabel, button] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                view.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(item: FileItem, status: BrowserModel.DirectorySizeStatus?, text: String,
                           canRequest: Bool, onRequest: @escaping () -> Void) {
        let showButton = canRequest && (status == nil || status == .unavailable)
        button.isHidden = !showButton
        statusLabel.isHidden = showButton
        self.onRequest = showButton ? onRequest : nil
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.linkColor
        ])
        button.setAccessibilityLabel(text + " — " + item.name)
        statusLabel.stringValue = text
        toolTip = status == .unavailable ? L("폴더 크기를 읽지 못했습니다.", "The folder size could not be read.") : nil
    }

    @objc private func requestSize(_ sender: Any?) { onRequest?() }
}

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
