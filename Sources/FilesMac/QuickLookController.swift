import AppKit
import FilesCore
@preconcurrency import QuickLookUI

@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []

    func present(items: [FileItem]) {
        urls = items.map(\.url)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.delegate = self; panel.currentPreviewItemIndex = 0
        panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func close() {
        guard let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil else { return }
        panel.orderOut(nil); panel.dataSource = nil; panel.delegate = nil; urls = []
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
#if DEBUG
    var qaVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true }
    var qaItemCount: Int { urls.count }
    var qaContentView: NSView? { QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared()?.contentView : nil }
#endif
}
