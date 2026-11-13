# M5 스물일곱 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- `/usr/bin/ssh-keyscan` timeout 5초, ed25519/ECDSA/RSA 후보 수집
- 서버 host를 프로세스 인자가 아닌 `-f -` 표준입력으로 전달
- 주석·빈 줄 제외, host/port 검증, 동일 후보 중복 제거
- 수집 결과는 신뢰되지 않은 후보로 유지하고 자동 저장하지 않음
- SFTP 프로필에서만 `호스트 키 확인` 버튼 활성화
- ed25519 우선 후보의 host:port, key type, SHA-256 fingerprint 표시
- 서버 관리자가 제공한 값과 직접 비교하라는 안내와 명시적 신뢰/취소 버튼
- 승인 시에만 기존 0600 trust 저장소에 기록

## 검증

- ssh-keyscan arguments에 host 문자열 부재, stdin에만 host 존재 확인
- 주석과 중복을 포함한 후보에서 두 key type만 반환 확인
- 주석뿐인 빈 후보 결과 거부 확인
- 전체 Swift Testing 137개 통과
- 한국어/영어 × 라이트/다크 UI 4조합에서 SFTP trust 명령 활성화와 기존 SMB 명령 복원 확인

## 남은 항목

- 실제 sshd 후보 수집·사용자 육안 fingerprint 대조 수용 검증
- 여러 key type을 모두 비교·선택하는 상세 UI
- identity file 선택·보안 scope 유지와 실제 SFTP 목록 연결

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
