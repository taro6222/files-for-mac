# M6 Increment 09 — 시작 세션 복원 설정

검증일: 2026-11-14

## 구현

- `BrowserPreferences.continueLastSession`을 기본 활성 상태로 추가하고 `UserDefaults`에 저장한다.
- 외형 설정 패널에 접근 가능한 “마지막 세션 계속” 체크박스를 추가했다.
- 앱 시작 시 설정이 켜진 경우에만 분할 workspace와 레거시 탭 세션을 복원하며, 꺼진 경우 새 창으로 시작한다.
- 원본의 `RestoreTabsOnStartup`은 macOS의 통합 탭·분할 workspace 복원 정책으로 대응하고, `ContinueLastSessionOnStartUp`은 구현 설정으로 연결했다.

## 검증

- 기본값, 변경 알림, 저장 후 새 인스턴스 복원을 단위 테스트로 검증한다.
- `swift test`: 154개 통과.
- `scripts/verify-ui.sh`: 한국어/영어 × 밝게/어둡게 4조합 통과.
- `scripts/audit-parity.py`: 설정 143행, 구현 7, 플랫폼 대체 4, 플랫폼 제외 2, 검토 대기 130; 전체 감사 유효.

## 남은 항목

- 시작 특정 경로, 새 탭 시작, 기존 인스턴스 열기 등 별도 시작 정책은 아직 검토 대기다.
