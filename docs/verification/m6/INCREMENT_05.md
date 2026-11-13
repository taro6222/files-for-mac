# M6 다섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 대응표 상태를 `implemented`, `platform-alternative`, `platform-excluded`, 검토 대기로 제한
- 구현·플랫폼 대체 명령에 mac command ID가 없으면 감사 실패하도록 강화
- Windows 전용 실행·셸·저장 모델 8개 제외 판정
- 드라이브 포맷 3개와 classic properties 1개를 macOS 네이티브 대체로 판정

## 검증

- `scripts/audit-parity.py --json` 통과
- 명령 202/202, 허용되지 않은 상태 0, 증거 누락 0
- `implemented` 40개
- `platform-alternative` 4개
- `platform-excluded` 8개
- `awaiting-behavior-review` 150개

## 플랫폼 결정

- 임의 파일·앱을 root 또는 다른 사용자로 실행하지 않는다.
- INF, PowerShell, NTFS ADS, Windows Start pin은 이름만 비슷한 macOS 기능으로 위장하지 않는다.
- 장치 포맷은 앱 내부 erase 대신 Disk Utility에 위임한다.
- classic properties는 검증된 네이티브 정보 패널로 대체한다.

남은 대기 항목과 설정·화면 대응이 있으므로 M6 완료로 표시하지 않는다.
