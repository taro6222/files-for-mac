# M7 Increment 02 — 로컬 회귀 및 AppKit 성능

2026-11-14, Apple Silicon macOS 27.2 (26B123), Swift 6.4.2. UI 측정 소스는 `db58c3ecfb80b20441888d66c80a810ae6a70c30`이다.

## 검증 결과

- Swift Testing 198개 통과.
- 한국어·어두운 테마 성능 시나리오에서 AppKit 217개 검사와 두 창 왕복 20회, 스크롤 위치 100개를 확인했다.
- 실제 APFS·대소문자 구분 APFS·exFAT 임시 볼륨의 탐지, 복사·이동·실행 취소 및 대소문자 동작 검사를 통과했다. 실제 macOS 시스템 휴지통 이동·복원도 통과했다.

- 루프백 FTP/FTPS/SFTP에서 실제 curl/OpenSSH 전송 검증을 각각 통과했다. 원격 서비스의 운영 계정과 외부 네트워크 시험은 별도다.

## AppKit 계측

| 항목 | 결과 |
|---|---:|
| 10,001개 항목 fixture 첫 표시 | 57.3 ms |
| 전체 열거·AppKit 표시 | 2.064 s |
| 스크롤 단계 p95 | 3.81 ms |
| 두 창 왕복 p95 | 4.721 s |

[원시 표본](performance.json)은 따뜻한 로컬 fixture에서 측정한 Debug 앱의 AppKit 처리 시간이다. 콜드 시작, 화면 합성 프레임, Release p95, 장시간 메모리는 별도로 검증한다. 전체 표시 단일 측정값은 2초 목표를 초과했다.
