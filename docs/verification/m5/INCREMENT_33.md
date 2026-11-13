# M5 서른세 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- localhost OpenSSH fixture에 실제 host key와 별도의 잘못된 Ed25519 host key 생성
- 동일 host·port에 잘못된 공개 키를 고정한 `known_hosts` fixture 구성
- `StrictHostKeyChecking yes`와 전용 `UserKnownHostsFile`을 사용하는 실제 provider 목록 요청
- host-key mismatch가 인증·목록 처리 전에 subprocess 실패로 종료되는지 확인
- 정상 pinned key의 목록·다운로드·rename capability probe 회귀 유지

## 검증

- `scripts/verify-sftp.sh` 실제 OpenSSH 수용 테스트 통과
- 올바른 pinned host key로 Unicode 목록·다운로드 통과
- 잘못된 pinned host key에서 `RemoteExecutionError.nonzeroExit` 확인
- 전체 Swift Testing 143개 통과
- 직전 UI 개발 단위의 한국어/영어 × 라이트/다크 4조합 결과 유지; 이번 단위는 UI 코드 변경 없음

## 남은 항목

- 서버 연결 중단과 대용량 다운로드 취소 시 subprocess 종료·staging 정리 수용 검증
- SFTP 연결 결과를 탐색 pane provider로 통합
- 외부 실제 서버에서 fingerprint 운영 절차 확인

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
