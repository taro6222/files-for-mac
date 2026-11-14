# M6 Increment 94 — 정보 pane

- 탐색 창의 오른쪽에서 선택 항목의 상세와 Quick Look 미리보기를 전환한다. 보기 옵션 또는 이동 메뉴에서 pane을 열 수 있다.
- 활성 pane의 선택을 따라가며, 단일 항목은 유형·크기·수정일·소유자·태그·경로를 표시한다. 다중 선택은 개수를 표시한다. 단일 파일 미리보기는 지원 포맷에 대해 macOS Quick Look이 렌더링한다.
- 창 또는 정보 pane을 닫거나 탭을 바꾸면 이전 미리보기를 해제하고, 취소된 속성 조회는 화면에 반영하지 않는다. 컴팩트 모드에서는 공간 확보를 위해 정보 pane을 숨긴다.
- 표시 여부와 마지막 탭은 앱 설정과 내보내기 아카이브에 저장한다. 기본값은 숨김과 상세 탭이다.
- [고정 원본 정보 pane 설정](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Services/Settings/InfoPaneSettingsService.cs)을 기준으로 표시와 탭 전환을 연결했다.

## 검증

- Swift Testing 193개 통과. 설정 내보내기와 가져오기 왕복을 확인했다.
- 한국어·영어 × 밝게·어둡게 AppKit UI 각 210개 통과. 선택 파일의 상세 경로, Quick Look에 전달한 URL, 닫은 뒤 해제, 최소 창에서 pane 폭을 확인했다.
- 900pt 창 캡처에서 오른쪽 pane 폭 240pt를 확인했다. Quick Look 콘텐츠 픽셀과 포맷별 렌더링은 별도 수용 검증 범위다.
- 패리티 감사 통과. 검토 대기는 명령 13개, 설정 9개다.
