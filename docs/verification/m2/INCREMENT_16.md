# M2 열여섯 번째 개발 단위: 분할 pane 상태 모델

작성일: 2026-11-13

## 구현 내용

- 한 탭에 하나 또는 두 개의 `PaneSnapshot`을 보관하는 `SplitTabState`를 추가했다.
- 좌우 분할(`vertical`)과 상하 분할(`horizontal`) 축을 명시적으로 저장한다.
- `activePaneID`를 단일 명령 대상으로 사용하며 활성 pane의 탐색 스냅샷만 갱신한다.
- 분할 비율을 20~80% 범위로 제한하고 잘못된 비율과 비정상 부동소수 값을 안전한 값으로 정규화한다.
- 두 번째 pane을 닫으면 첫 pane을 활성화하고 비율을 50%로 되돌린다.
- 전체 분할 상태는 Codable이며 pane ID·축·비율·활성 pane을 JSON 왕복할 수 있다.

## 검증

- Swift 패키지 캐시를 정리한 뒤 전체 테스트 실행
- `DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp swift package clean`
- `DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp swift test`
- Swift Testing 67개 통과
- `FilesCore`, `FilesCoreTests`, `FilesMac` 빌드 통과
- 활성 pane만 갱신, 축 변경, 비율 제한, pane 닫기, JSON 왕복 테스트 통과

## 제한 및 다음 단계

- 이번 단위는 데이터·명령 대상 계약이며 실제 화면에 두 파일 목록을 아직 배치하지 않았다.
- 분할 divider의 실제 위치와 상태 모델 비율 동기화, 키보드 focus/VoiceOver 이동은 UI 연결 단계에서 검증한다.
- 탭 드래그를 분할로 전환하는 동작은 네이티브 탭 drag 이벤트의 공개 API 범위를 별도로 확인해야 한다.
- 다음 단계는 AppKit 분할 컨테이너, pane별 `BrowserModel`, 활성 테두리와 메뉴/단축키 라우팅 연결이다.
