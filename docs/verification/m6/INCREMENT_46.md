# M6 Increment 46 — pane 제어 명령

검증일: 2026-11-14

## 구현

- 기존 두 pane을 좌우 또는 상하로 즉시 재배치하고 divider를 중앙에 안정화한다.
- 다른 pane 초점 명령은 활성 상태와 실제 파일 목록 first responder를 함께 전환한다.
- 현재 폴더를 반대 pane에서 열며, pane이 없으면 같은 보기 모드로 새 pane을 만든다.
- dual pane 전환은 단일 pane에서 좌우 분할을 만들고 분할 상태에서는 보조 pane을 안전하게 닫는다.
- 분할이 필요한 명령은 단일 pane일 때 비활성화하고 메뉴·명령 팔레트에 같은 action을 노출한다.

## 검증

- 방향 전환 후 workspace axis, 활성 pane ID 전환, 양 pane의 동일 현재 위치, dual pane 닫기·재생성을 UI 자동화로 확인한다.
- Swift 전체 테스트 169개, 한국어/영어 × 밝게/어둡게 UI 4개 조합, 패리티 감사가 통과했다.

`CloseActivePane`은 주 pane을 닫을 때 보조 pane의 전체 history·selection을 손실 없이 승격해야 하므로 별도 구현 항목으로 유지한다.
