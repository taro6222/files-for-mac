# M2 열일곱 번째 개발 단위: AppKit 분할 탐색 UI

작성일: 2026-11-13

## 구현 내용

- 기본 탐색 영역을 `NSSplitView` 작업 공간으로 바꾸고 좌우(`⌥⌘D`)·상하(`⌥⇧⌘D`) 분할 메뉴를 연결했다.
- 보조 pane은 독립 `BrowserModel`, 경로 입력, 뒤로·앞으로·상위 폴더·새로고침, 파일 목록과 상태 표시를 가진다.
- 보조 pane의 선택·스크롤·히스토리는 주 pane과 섞이지 않는다.
- 선택하거나 키보드 초점을 받은 pane을 파란 테두리로 표시한다.
- 메뉴의 뒤로·앞으로·상위·새로고침·읽기 중단·경로/파일 목록 초점 명령을 활성 pane에 전달한다.
- `⌥⌘W`로 보조 pane을 닫고 주 pane으로 초점을 복귀한다.
- 보조 pane이 활성일 때 파일 변경 명령을 비활성화해 주 pane의 선택에 잘못 적용되는 것을 방지한다.

## 검증

- `DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp swift test`
- Swift Testing 67개 통과
- 새 `SecondaryBrowserPane`을 포함한 `FilesMac` 앱 타깃 빌드 통과
- 분할 상태 코어의 활성 pane·비율·직렬화 테스트 및 기존 파일 작업 회귀 테스트 통과

## 제한 및 다음 단계

- 보조 pane의 파일 열기와 탐색은 동작하지만 생성·복사·이동·삭제·이름 변경은 아직 비활성화돼 있다.
- 보조 pane은 현재 폴더 감시와 사이드바·홈·보기 옵션을 제공하지 않는다.
- divider 비율과 두 번째 pane 상태를 앱 재실행 세션에 아직 저장하지 않는다.
- 실제 화면에서 divider drag, 최소 창 크기, 한국어/영어, VoiceOver focus 순서를 수동 검증해야 한다.
- 다음 단계는 공통 pane 명령 컨텍스트를 만들어 모든 파일 작업을 활성 pane에 연결하고 분할 세션을 복원하는 것이다.
