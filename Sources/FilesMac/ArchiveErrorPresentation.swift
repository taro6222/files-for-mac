import Foundation
import FilesCore

func archiveExtractionErrorMessage(_ error: Error, encrypted: Bool) -> String {
    if encrypted {
        switch error {
        case ZipArchiveError.readFailed, ZipArchiveError.cannotOpen:
            return L("추출하지 못했습니다. 암호와 압축 파일을 확인한 뒤 다시 시도하세요.", "Extraction failed. Check the password and archive, then try again.")
        default: break
        }
    }
    return archiveErrorMessage(error)
}

func archiveErrorMessage(_ error: Error) -> String {
    switch error {
    case let SevenZipVolumeError.missingPart(number):
        return L("분할 압축 파일의 \(String(format: "%03d", number))번 볼륨이 없습니다. 모든 볼륨을 같은 폴더에 모은 뒤 다시 여세요.", "Archive volume \(String(format: "%03d", number)) is missing. Put all volumes in the same folder and reopen the archive.")
    case let SevenZipVolumeError.invalidPart(url):
        return L("분할 볼륨이 변경되었거나 크기가 올바르지 않습니다: ", "A split volume changed or has an invalid size: ") + url.lastPathComponent
    case SevenZipVolumeError.tooManyParts, SevenZipVolumeError.sizeLimit:
        return L("분할 볼륨 수 또는 전체 크기가 처리 한도를 넘었습니다.", "The split archive exceeds the volume count or total size limit.")
    case SevenZipVolumeError.sdkRequired:
        return L("분할 7z를 열려면 압축 구성 요소가 포함된 앱이 필요합니다.", "Opening split 7z archives requires the app's bundled archive components.")
    case SevenZipWorkerError.worker("password-required"), SevenZipWorkerError.worker("password-or-corrupt"):
        return L("암호가 없거나 올바르지 않습니다. 암호와 압축 파일을 확인한 뒤 다시 시도하세요.", "The password is missing or incorrect. Check the password and archive, then try again.")
    case SevenZipWorkerError.worker("missing-volume"):
        return L("분할 볼륨이 누락되었거나 마지막 볼륨이 잘렸습니다. 모든 볼륨을 확인한 뒤 다시 여세요.", "A volume is missing or the last volume is truncated. Check all volumes and reopen the archive.")
    case SevenZipWorkerError.worker("source-changed"):
        return L("압축 파일이 작업 중 변경되어 중단했습니다. 파일을 다시 열어 시도하세요.", "The archive changed during the operation. Reopen it and try again.")
    case SevenZipWorkerError.worker("limit"):
        return L("압축 해제 항목 수나 크기가 안전 한도를 넘어 중단했습니다.", "The archive exceeds the safe item or size limit.")
    case SevenZipWorkerError.worker("unsupported-item"), SevenZipWorkerError.worker("invalid-metadata"):
        return L("안전하게 추출할 수 없는 경로나 항목이 있어 중단했습니다.", "The archive contains an unsafe path or entry.")
    case let SevenZipWorkerError.stagingPreserved(url):
        return L("임시 결과가 변경되어 자동 삭제하지 않았습니다. 확인할 위치: ", "Temporary output changed and was preserved. Inspect: ") + url.path
    case let SevenZipWorkerError.publicationRecovery(staging, published):
        return L("일부 결과가 변경되어 되돌리지 않았습니다. 다음 위치를 확인하세요: ", "Some results changed and were preserved. Inspect: ") + ([staging] + published).map(\.path).joined(separator: " · ")
    case is SevenZipBundleError, SevenZipWorkerError.unavailable:
        return L("압축 구성 요소를 확인할 수 없습니다. 앱을 다시 설치한 뒤 시도하세요.", "The archive components could not be verified. Reinstall the app and try again.")
    case SevenZipWorkerError.timedOut:
        return L("압축 처리 제한 시간이 지나 중단했습니다. 다른 파일을 선택하거나 다시 시도하세요.", "Archive processing timed out. Choose another file or try again.")
    case is SevenZipWorkerError:
        return L("압축 파일을 처리하지 못했습니다. 파일과 저장 위치를 확인하세요.", "The archive could not be processed. Check the file and destination.")
    case ZipArchiveError.emptyPassword:
        return L("비어 있지 않고 NUL 문자를 포함하지 않는 암호를 입력하세요.", "Enter a nonempty password without NUL characters.")
    case ZipArchiveError.unsupportedEncryption:
        return L("이 포맷의 암호 작업을 지원하지 않습니다.", "Password-protected operations are not supported for this format.")
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
