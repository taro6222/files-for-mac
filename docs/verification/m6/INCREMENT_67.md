# M6 Increment 67 — 위치별 열기·활성 pane 닫기

검증일: 2026-11-14

## 구현

- 홈과 사이드바가 공유하는 위치 버튼 메뉴에서 새 탭, 새 창, 반대 pane 열기를 제공한다.
- Windows 원본의 화면별 중복 action은 macOS의 통합 위치 메뉴로 대응하되 실제 대상 URL을 sender에서 명시적으로 전달한다.
- 활성 보조 pane을 닫고, 주 pane이 활성일 때는 보조 pane snapshot을 주 pane으로 승격해 사용자의 남은 탐색 상태를 보존한다.
- 활성 pane 닫기 명령을 메뉴·명령 팔레트에 연결하고 분할 상태에서만 활성화한다.

## 자동 검증

- 위치 메뉴 action이 represented URL을 사용하고 기존 선택 기반 context action과 충돌하지 않는지 UI 회귀로 확인한다.
- 활성 pane 닫기 selector의 명령 팔레트 등록과 기존 분할 생성·닫기·복원 흐름을 확인한다.
- 전체 Swift Testing과 한국어/영어 × 밝게/어둡게 UI 4개 조합 및 패리티 감사를 실행한다.
