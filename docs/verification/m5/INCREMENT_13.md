# M5 열세 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- FTP, FTPS, SFTP, SMB 연결 프로필 도메인 모델
- 프로토콜별 기본 포트와 직접 연결/마운트 방식 분리
- FTPS 인증서 검증, SFTP host key 검증, SMB 마운트 capability 명시
- 이름·호스트·포트·절대 루트 경로 정규화와 검증
- 호스트/사용자 필드에 내장된 자격증명 형태 거부
- 저장 프로필에는 비밀값 대신 불투명 Keychain 참조만 허용

## 검증

- SFTP 프로필 공백 제거, 호스트 소문자화, 기본 포트 및 비밀 없는 endpoint 확인
- JSON 왕복 후 프로필 동일성과 password 문자열 부재 확인
- 네 프로토콜의 기본 포트·직접/마운트·TLS·host key capability 확인
- 빈 이름, 공백 포함 호스트, `user@host`, 범위 밖 포트, 상대 경로, `user:name` 거부 확인
- 전체 Swift Testing 114개 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과

## 남은 항목

- 프로필 저장소와 macOS Keychain 자격증명 adapter
- 연결 편집 UI, 재인증, 인증서/host key 신뢰 흐름
- FTP/FTPS/SFTP 목록·전송·취소·재시도 backend
- SMB 실제 마운트 연결 및 파일 작업 수용 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
