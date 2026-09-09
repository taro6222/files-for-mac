# INCREMENT 06 — 영구 삭제

작성일: 2026-09-10

## 목표
- 선택 항목을 휴지통을 거치지 않고 영구 삭제할 수 있게 한다.
- 삭제 요청을 항목 단위 결과(`completed`/`notFound`/`failed`)와 저널 상태로 보여준다.
- 삭제 진행 중 다른 파일 작업(복사, 이름 변경, 이동, 복원, 영구 삭제)과 충돌하지 않게 가드한다.

## 구현 요약
- Core: `EntryOperations.permanentlyDelete(_:)` 추가
  - 파라미터: `sources: [URL]`, `journalDirectory: URL`
  - 리턴: `PermanentDeleteOperationResult` (`id`, `state`, `items`, `journalError`)
  - 항목 상태: `queued` 시작 후 `completed`/`notFound`/`failed` 기록
  - 저널 파일: `permanent-delete-<UUID>.json`
- macOS UI: `PermanentDeleteWindow` 추가
  - 항목 리스트, 진행 상태 라벨, 완료/실패 메시지 표시, 저널 저장 오류 표시
- BrowserWindow:
  - 파일 메뉴/컨텍스트 메뉴에 "영구 삭제…" 추가
  - 확인 다이얼로그(복구 불가 경고) 후 `PermanentDeleteWindow` 실행
  - `canPermanentDeleteSelection`, `validateMenuItem` 바인딩
- 종료 가드: 영구 삭제 작업창 동작 중 앱 종료 제한

## 단위 테스트
- `Tests/FilesCoreTests/EntryOperationsTests.swift`
  - `entryPermanentDeleteRemovesExistingItemsAndReportsState`
    - 파일/폴더 영구 삭제가 성공하는지, 완료 상태인지 검증
  - `entryPermanentDeleteTracksMissingAndFailed`
    - 존재/미존재 조합에서 `partial`, `notFound`를 포함한 항목별 상태 검증

## 확인 항목
- `swift test --filter entryPermanentDelete` 통과
- `swift test` 통과

