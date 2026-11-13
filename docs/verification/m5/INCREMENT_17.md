# M5 열일곱 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- `/usr/bin/curl`을 FTP/FTPS backend, `/usr/bin/sftp`를 SFTP backend 후보로 탐지
- SMB는 직접 provider 목록에서 제외하고 기존 Finder 마운트 경로 유지
- FTP/FTPS 목록·다운로드·업로드용 curl 명령 계획
- 비밀번호를 프로세스 인자·URL·redacted 진단 문자열에 넣지 않고 표준입력 config로 전달
- curl 사용자 설정 파일을 읽지 않도록 `-q`를 첫 인자로 사용
- FTPS에서 인증서 검증을 약화하지 않고 TLS 요구 옵션 추가
- 원격 경로 제어문자·상대 경로 및 줄바꿈 포함 자격증명 거부

## 검증

- 현재 macOS curl의 FTP/FTPS 및 OpenSSH SFTP 실행 파일 탐지 확인
- FTP/FTPS 각각 기본 포트·Unicode/공백 경로·다운로드 계획 확인
- arguments와 redacted description에 host·username·secret 부재 확인
- FTPS에만 `ssl-reqd` 적용 확인
- SFTP 프로필, 상대 경로, 줄바꿈 사용자 이름 거부 확인
- 전체 Swift Testing 120개 및 UI 한국어/영어 × 라이트/다크 4조합 통과

## 남은 항목

- subprocess 실행·출력 한도·취소·오류 분류와 FTP/FTPS 실제 서버 fixture
- 다운로드 staging/publish 및 업로드 실패 시 부분 파일 처리
- SFTP host key 신뢰 저장과 인증·목록·전송 구현

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
