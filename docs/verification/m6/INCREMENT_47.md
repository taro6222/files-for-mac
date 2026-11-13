# M6 Increment 47 — 숨김 파일·설정·개발 앱 명령 재조정

검증일: 2026-11-14

## 대응

- `ToggleDotFilesSetting` → macOS 숨김 파일 표시 전환. Finder 관례의 Shift-Command-. 단축키, UserDefaults 영속화, 열린 모든 창 동기화를 사용한다.
- `OpenSettings` → macOS 일반 설정 창. 원본의 단일 settings route 대신 네이티브 유틸리티 창이며 다른 설정 화면은 앱 메뉴에서 독립적으로 연다.
- `OpenInIDE` → 사용자가 개발자 도구 설정에서 선택한 macOS 앱으로 선택 항목 또는 현재 위치를 연다. 앱 경로는 절대 경로만 저장하고 shell 문자열 결합을 사용하지 않는다.

## 증거

- 숨김 항목 필터·확장자 표시 identity·설정 영속화 단위 테스트
- 일반 설정 창의 모든 제어 왕복과 4개 UI 조합 캡처
- 개발 앱 설정 선택·초기화·영속화와 `NSWorkspace.open` 기반 실행 경계
- 세 action의 주 메뉴·명령 팔레트 등록 자동 확인

Swift 전체 테스트 169개, 한국어/영어 × 밝게/어둡게 UI 4개 조합, 패리티 감사가 통과했다.
