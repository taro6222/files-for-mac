# M2 열여덟 번째 개발 단위: 활성 pane 파일 작업

작성일: 2026-11-13

## 구현 내용

- `activeModel`과 `activeSelectedItems`를 공통 명령 컨텍스트로 추가했다.
- 새 폴더, 단일·배치 이름 변경, 복사, 이동, 휴지통 이동·복원, 영구 삭제가 활성 pane의 위치와 선택을 사용한다.
- Finder 파일 URL 클립보드 복사·붙여넣기도 활성 pane에 연결했다.
- 파일 작업 완료 시 작업을 시작한 pane의 `BrowserModel`을 새로고침해 사용자가 중간에 다른 pane을 선택해도 잘못된 목록을 갱신하지 않는다.
- 폴더 선택 창의 결과와 즐겨찾기 전환도 활성 pane 위치에 적용한다.
- 메뉴 활성 조건이 주 pane의 숨은 선택이 아니라 활성 pane의 로딩·선택·작업 상태를 검사한다.

## 검증

- `DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp swift test`
- Swift Testing 67개 통과
- `FilesMac` 앱 타깃과 공통 pane 라우팅 컴파일 통과
- 기존 복사·이동·삭제·이름 변경의 충돌·취소·identity 회귀 테스트 통과

## 제한 및 다음 단계

- 보조 pane은 아직 독립 폴더 감시를 제공하지 않아 외부 변경은 수동 새로고침이 필요하다.
- 보조 pane의 보기 옵션은 상세 보기 고정이며 숨김 항목 버튼과 사이드바는 없다.
- 분할 상태와 divider 위치는 앱 재실행 세션에 아직 포함하지 않는다.
- 실제 UI에서 두 pane을 번갈아 선택하며 파괴적 명령의 대상 경로를 확인하는 수동 테스트가 남아 있다.
- 다음 단계는 `SplitTabState`를 세션 저장 형식에 연결하고 두 pane·축·비율·활성 pane을 재실행 복원하는 것이다.
