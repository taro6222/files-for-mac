import AppKit
import FilesCore
import UniformTypeIdentifiers

@MainActor
func fileIcon(for item: FileItem, showsThumbnails: Bool) -> NSImage {
    if showsThumbnails { return NSWorkspace.shared.icon(forFile: item.url.path) }
    let type: UTType
    if item.isDirectory { type = item.isPackage ? .bundle : .folder }
    else { type = UTType(filenameExtension: item.url.pathExtension) ?? .data }
    return NSWorkspace.shared.icon(for: type)
}
