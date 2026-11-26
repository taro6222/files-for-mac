import AppKit
@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.addItem(withTitle: "")
        for index in 0..<11 { button.addItem(withTitle: "Home"); button.lastItem?.tag = index }
        button.addItem(withTitle: "Long title"); button.lastItem?.tag = 11
        let data = try JSONSerialization.data(withJSONObject: ["requestedTabCount": 12,
            "actualMenuItemCount": button.numberOfItems, "titles": button.itemTitles,
            "tags": button.itemArray.map(\.tag)], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
