# M5 스물다섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- SFTP private SSH config를 무작위 전용 임시 디렉터리에 생성
- 임시 디렉터리 mode 0700, config mode 0600, 쓰기 후 fsync
- `<private-config>` placeholder가 정확히 한 개인 계획만 실행
- 최대 64KiB config 제한
- 기존 취소 가능한 subprocess executor에 batch stdin 연결
- 성공·오류·취소 후 임시 디렉터리 전체 삭제
- SFTP `ls -1` UTF-8 parsing, 절대 locator 결합, 항목 수 제한

## 검증

- 실제 `/usr/bin/stat` subprocess에서 config mode 600 확인
- 실제 `/bin/cat`으로 private config와 batch stdin 내용 전달 확인
- 두 실행 모두 temporary root 잔존 0개 확인
- placeholder 누락·중복 계획 실행 전 거부 확인
- Unicode 목록과 parent locator 확인, 잘못된 UTF-8·slash 항목·한도 초과 거부
- 전체 Swift Testing 134개 및 UI 한국어/영어 × 라이트/다크 4조합 통과

## 남은 항목

- ssh-keyscan 결과를 자동 신뢰하지 않고 fingerprint를 사용자에게 제시하는 승인 UI
- 승인된 host key의 원자적 0600 known_hosts 저장·변경 탐지
- 실제 localhost sshd key 인증·목록·전송·취소 수용 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
