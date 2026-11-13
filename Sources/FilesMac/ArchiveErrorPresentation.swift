import Foundation
import FilesCore

func archiveErrorMessage(_ error: Error) -> String {
    switch error {
    case ZipArchiveError.destinationNotDirectory:
        return L("추출 대상으로 쓸 수 있는 폴더를 선택하세요.", "Choose a writable folder for extraction.")
    case let ZipArchiveError.destinationConflict(name):
        return L("대상에 이미 ‘\(name)’ 항목이 있습니다. 다른 폴더나 이름을 선택하세요.", "An item named ‘\(name)’ already exists. Choose another folder or name.")
    case ZipArchiveError.cannotOpen:
        return L("압축 파일을 열 수 없습니다. 손상되었거나 지원하지 않는 포맷일 수 있습니다.", "The archive cannot be opened. It may be damaged or use an unsupported format.")
    case ZipArchiveError.invalidEntry, ArchiveValidationError.invalidPath, ArchiveValidationError.duplicatePath, ArchiveValidationError.unsupportedEntry:
        return L("압축 파일에 안전하게 추출할 수 없는 경로나 항목이 있어 작업을 중단했습니다.", "The operation stopped because the archive contains an unsafe path or entry.")
    case ArchiveValidationError.tooManyEntries, ArchiveValidationError.invalidSize, ArchiveValidationError.singleFileLimit, ArchiveValidationError.totalSizeLimit:
        return L("압축 해제 항목 수나 크기가 안전 한도를 넘어 작업을 중단했습니다.", "The operation stopped because the archive exceeds the safe item or size limit.")
    case ZipArchiveError.invalidSource:
        return L("원본이 변경되었거나 링크·특수 항목이 포함되어 ZIP을 생성할 수 없습니다.", "The ZIP cannot be created because a source changed or contains a link or special item.")
    case ZipArchiveError.readFailed, ZipArchiveError.publishFailed:
        return L("압축 데이터를 처리하거나 결과를 저장하지 못했습니다. 원본과 기존 항목은 변경하지 않았습니다.", "Archive data could not be processed or published. Sources and existing items were left unchanged.")
    default:
        return error.localizedDescription
    }
}
