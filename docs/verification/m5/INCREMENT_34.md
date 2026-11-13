# M5 서른네 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- localhost OpenSSH fixture에 256MB sparse 원격 파일 생성
- 실제 SFTP 다운로드 subprocess를 시작한 뒤 20ms 시점에 Swift task 취소
- 취소를 실행 중 `sftp` process terminate로 전달
- 취소 결과를 `CancellationError`로 분류
- 최종 목적지 publish 금지와 same-directory staging 파일 정리 확인

## 검증

- `scripts/verify-sftp.sh` 실제 OpenSSH 대용량 다운로드 취소 통과
- 취소 후 최종 `cancelled.bin`이 생성되지 않음 확인
- 취소 후 `.files-sftp-download-*` staging 잔여물 없음 확인
- 정상 목록·소형 다운로드·rename capability·host-key mismatch 회귀 통과
- 전체 Swift Testing 143개 통과
- 이번 단위는 UI 코드 변경 없음; 직전 4조합 UI 검증 결과 유지

## 남은 항목

- 연결 결과를 탐색 pane provider로 통합
- byte 단위 진행률 제공
- 외부 네트워크 지연·강제 연결 단절 수용 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
