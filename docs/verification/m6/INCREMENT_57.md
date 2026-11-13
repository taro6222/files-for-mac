# M6 Increment 57 — 그룹 상태 저장·복원

검증일: 2026-11-14

## 구현

- `TabSnapshot`에 그룹 필드, 오름·내림 방향, 날짜 그룹 단위를 저장한다.
- 기존 JSON에 그룹 필드가 없으면 `none/ascending/year`로 복구해 이전 세션 호환성을 유지한다.
- `BrowserModel`이 snapshot 복원과 생성 시 그룹 상태를 왕복하고, 변경 시 UI 갱신 알림을 발생시킨다.
- 작업공간·분할 pane·닫은 탭 복원은 기존 `TabSnapshot` 합성을 통해 같은 그룹 상태를 자동으로 보존한다.

## 자동 검증

- 그룹 상태 JSON 왕복, 모델 복원, 모델 변경 후 snapshot 반영을 확인한다.
- 기존 snapshot의 상세 보기 기본값 테스트에 그룹 기본값 마이그레이션 검증을 추가한다.
- UI 섹션이 연결되기 전까지 관련 원본 명령은 `awaiting-behavior-review`로 유지한다.
