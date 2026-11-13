import Foundation
import FilesCore

func fileGroupTitle(_ key: String, field: FileGroupField) -> String {
    let value = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
    if value == "unknown" { return L("알 수 없음", "Unknown") }
    switch field {
    case .none: return ""
    case .name, .kind: return value
    case .modified:
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
