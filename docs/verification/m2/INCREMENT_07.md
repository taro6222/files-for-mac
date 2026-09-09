# M2 일곱 번째 개발 단위: 이동 동선

작성일: 2026-09-10

## 구현 내용

- `Sources/FilesCore/EntryOperations.swift`에 배치 이동 API를 추가했다.
  - 항목 배열을 목적지 폴더로 이동
  - 항목별 상태(`completed/failed/conflict/notFound`)와 최종 상태(`completed/partial/failed`)를 유지
  - 충돌 정책(`skip`, `replace`) 지원
  - 항목별 저널 `move-<UUID>.json` 기록
- macOS UI에 이동 동선을 추가했다.
  - 파일 메뉴: `선택 항목 이동…` (⌘⇧V)
  - 문맥 메뉴: `선택 항목 이동…`
  - `NSOpenPanel`로 대상 폴더 선택
  - 충돌 정책 선택 후 `MoveWindow`(항목별 상태 리포트)로 실행
- 실행 중 종료 방지 및 중단 가드에 이동 창 반영
  - 메뉴 유효성/종료 동작에 `MoveWindow.isRunning` 반영

## 테스트

### 단위 테스트

- `Tests/FilesCoreTests/EntryOperationsTests.swift`
  - `entryMoveMovesItemsIntoDestination`
    - 이동 대상이 목적지로 이동하고 소스가 삭제되며 완료 상태 확인
  - `entryMoveSkipsConflicts`
    - 충돌 항목 시 `conflict` + `partial` 상태 확인, 소스 보존 확인

### 정적 점검

- 이동 메뉴·문맥 메뉴의 노출 여부 및 중복 창 가드 연결 확인
- 무효 입력(동일 선택 없음, 목적지 미지정 등)에서 조기 리턴 동작 확인

## 제한 및 다음 단계

- 현재 이동은 `MoveConflictPolicy.replace`에서 기존 항목 삭제 후 이동하도록 처리한다.
- 실행 취소(Undo)는 아직 미구현이며 다음 단계에서 제약 조건·원복 정책을 정하고 검증해야 한다.

