# M5 스물네 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- OpenSSH `/usr/bin/sftp` batch 기반 list/get/put/rm 명령 계약
- 서버 주소·사용자·키·trust 경로를 프로세스 인자 대신 private SSH config로 격리
- `StrictHostKeyChecking yes`와 전용 `UserKnownHostsFile` 강제
- `IdentitiesOnly yes`, `BatchMode yes`, password·keyboard-interactive 인증 차단
- 사용자 승인 없이 host key를 자동 추가하거나 인증 실패를 우회하지 않음
- identity와 known_hosts가 일반 파일이며 링크가 아닌지 실행 전 검증
- remote/local 절대 경로 quoting과 quote·backslash escape

## 검증

- custom port, host, user, identity, known_hosts가 private config에만 존재하는지 확인
- 공개 arguments가 임시 config placeholder와 무의미 alias만 포함하는지 확인
- strict host key 및 key-only 옵션 전체 확인
- Unicode/공백/quote 경로 batch escape 확인
- 상대 경로·공백 사용자·FTP 프로필 거부 확인
- 정상 identity/trust 통과, link trust와 missing identity 거부 확인
- 전체 Swift Testing 131개 및 UI 한국어/영어 × 라이트/다크 4조합 통과

## 남은 항목

- private config를 mode 0600 임시 파일로 생성·동기화·삭제하는 executor
- host key fingerprint 확인·사용자 승인·known_hosts 저장 UI
- 실제 localhost sshd에서 목록·다운로드·업로드·취소 수용 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
