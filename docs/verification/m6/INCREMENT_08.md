# M6 Increment 08 — 첫 설정 대응 매핑

검증일: 2026-11-14

## 범위

- 실제 `UserDefaults` 저장·복원과 창 반영이 확인되는 앱 테마, 숨김 항목, 확장자, 홈의 즐겨찾기·최근·드라이브 표시를 `implemented`로 연결했다.
- Windows Mica, IDE 선택 범위, dot-file 분리 설정은 macOS 네이티브 동작 차이를 숨기지 않고 `platform-alternative`로 기록했다.
- Windows 보호 시스템 파일과 NTFS ADS 설정은 macOS에 같은 의미가 없어 `platform-excluded`로 기록했다.
- 원본 143개 설정 중 코드와 테스트 증거가 없는 항목은 계속 검토 대기로 남겼다.

## 검증

- `swift test`: 153개 통과.
- `scripts/audit-parity.py`: 설정 143행, 구현 6, 플랫폼 대체 3, 플랫폼 제외 2, 검토 대기 132; 전체 감사 유효.
- 기존 단위 테스트가 테마·숨김·확장자·홈 섹션의 저장과 새 `BrowserPreferences` 인스턴스 복원을 검증한다.

## 남은 항목

- 탭/창 세션, 사이드바, 컬럼 폭/표시, 보기 크기 설정을 실제 구현과 대조한다.
- 단순히 앱에 비슷한 화면이 있다는 이유만으로 원본 설정을 구현 처리하지 않는다.
