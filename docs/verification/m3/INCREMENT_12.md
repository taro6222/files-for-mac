# M3 열두 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 실제 `keyDown`과 `charactersIgnoringModifiers`를 사용하는 네이티브 단축키 recorder
- Command·Option·Control·Shift 조합 및 방향키·Delete·Escape·Space·Tab 정규화
- 기본 단축키와 사용자 override 분리 저장 및 재실행 복원
- 다른 명령과의 중복, 수정키 없는 입력, macOS 예약 조합 차단
- 전체 기본값 복원과 알 수 없는 명령 override 제거
- 메뉴 단축키 변경 즉시 반영 및 명령 팔레트 표시 연동
- 한국어 IME 문자열 입력이 아닌 물리 키 이벤트 기반 기록

## 자동 및 실제 UI 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 85개 테스트 통과. 단위 테스트에서 저장·재로딩, 대소문자 정규화, 충돌, 수정키 누락, 시스템 예약 조합, 전체 초기화를 검증했다.

`DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 `shortcutSettingsCommands`, `shortcutSettingsWindow`를 포함한 모든 검사가 `true`였다. 각 조합의 `keyboard-shortcuts.png`를 생성하고 한국어 다크 화면의 카테고리·명령·특수키·recorder·초기화 컨트롤을 직접 확인했다.

## 남은 항목

- 툴바 표시·순서·overflow 사용자 지정
- 테마·재질 및 폴더별 보기 설정의 원본 동작 대조
- VoiceOver로 recorder와 충돌 오류 직접 확인
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
