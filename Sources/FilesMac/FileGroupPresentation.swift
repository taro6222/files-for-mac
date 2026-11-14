import Foundation
import FilesCore

func fileGroupTitle(_ key: String, field: FileGroupField) -> String {
    let value = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
    if value == "unknown" { return L("알 수 없음", "Unknown") }
    switch field {
    case .none: return ""
    case .name, .kind, .tag: return value == "untagged" ? L("태그 없음", "Untagged") : value
    case .syncStatus: return cloudStateTitle(CloudItemState(rawValue: value))
    case .path: return value
    case .created, .modified:
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first else { return value }
        if parts.count > 2, parts[2] > 0 { return String(format: "%04d-%02d-%02d", year, parts[1], parts[2]) }
        if parts.count > 1, parts[1] > 0 { return String(format: "%04d-%02d", year, parts[1]) }
        return String(year)
    case .size:
        switch value {
        case "folder": return L("폴더", "Folders")
        case "empty": return L("빈 파일", "Empty Files")
        case "small": return L("1MB 미만", "Under 1 MB")
        case "medium": return L("1MB–1GB", "1 MB–1 GB")
        case "large": return L("1GB 이상", "1 GB and Larger")
        default: return value
        }
    }
}

func cloudStateTitle(_ state: CloudItemState?) -> String {
    switch state {
    case .availableOffline: return L("오프라인 사용 가능", "Available Offline")
    case .onlineOnly: return L("온라인 전용", "Online Only")
    case .downloading: return L("다운로드 중", "Downloading")
    case .uploading: return L("업로드 중", "Uploading")
    case .conflict: return L("충돌", "Conflict")
    case .error: return L("오류", "Error")
    case .unknown: return L("알 수 없음", "Unknown")
    case nil: return L("상태 정보 없음", "No Status Available")
    }
}

enum DetailDisplayRow: Equatable {
    case header(String)
    case item(FileItem)
}

func detailDisplayRows(items: [FileItem], grouping: FileGroupOptions) -> [DetailDisplayRow] {
    if grouping.field == .none { return items.map(DetailDisplayRow.item) }
    let groups = FileGrouping.groups(items, options: grouping)
    return groups.flatMap { group in
        [DetailDisplayRow.header(fileGroupTitle(group.key, field: grouping.field))] + group.items.map(DetailDisplayRow.item)
    }
}

func detailItem(at row: Int, in rows: [DetailDisplayRow]) -> FileItem? {
    guard rows.indices.contains(row), case let .item(item) = rows[row] else { return nil }
    return item
}

func detailSelectionRows(ids: Set<String>, in rows: [DetailDisplayRow]) -> IndexSet {
    guard !ids.isEmpty else { return [] }
    return IndexSet(rows.indices.filter { detailItem(at: $0, in: rows).map { ids.contains($0.id) } == true })
}
