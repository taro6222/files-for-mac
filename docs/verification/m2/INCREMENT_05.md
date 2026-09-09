# M2 다섯 번째 개발 단위: 휴지통 복원 준비

날짜: 2026-09-10. M2 진행 중.

## 구현 내용

- `EntryOperations.restoreFromTrash(sources:to:journalDirectory:)`를 추가했다.
  - 입력이 비어 있으면 `EntryOperationError.noSources`를 반환한다.
  - 작업 시작 전 `restore-<UUID>.json` 저널을 생성해 상태를 기록하고, 항목 단위(`source`, `target`, `state`, `message`, `updatedAt`) 진행 상태를 누적한다.
  - 각 항목을 검사해 휴지통 항목인지 확인하고, 대상 폴더에 동일 이름이 있으면 충돌로 처리한다.
  - 복원은 `FileManager.moveItem(at:to:)`로 수행하며, 결과 상태는 `completed/failed/conflict`를 유지해 창에서 표시한다.
- UI에서 항목별 복원 창을 띄우기 위해 `RestoreWindow`를 추가했다.
  - 복원 진행 중엔 종료 불가, 완료/실패 시 상태 메시지와 항목 결과를 정리해 보여준다.
- 브라우저 동작을 연결했다.
  - 파일/문맥 메뉴에 `휴지통에서 복원…` 액션 추가.
  - 대상 폴더를 먼저 선택하도록 `NSOpenPanel`을 띄우고 `RestoreWindow.start(sources:destination:)`로 처리.
  - 메뉴 검증은 `canRestoreSelection`으로 제어.
- 종료 가드에 `RestoreWindow.isRunning`을 반영했다.

## 검증

- 휴지통 복원 단위 테스트 추가:
  - `EntryOperations.restoreFromTrash`가 실제로 `moveToTrash`에서 생성된 항목을 되돌리고, 결과 상태가 `completed`인지 확인.
  - 휴지통이 아닌 항목을 복원 시도할 때 `failed` 처리와 `partial` 상태를 확인.

## 다음 단계

- 휴지통 목록 탐색 최적화(시스템 기본 trash 위치 탐색 경로 보강), 복원 대상 충돌 재시도, 영구 삭제 및 undo 동선은 후속 단계에서 진행한다.
