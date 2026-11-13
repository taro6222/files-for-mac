# M5 열여섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- SMB 프로필에서 macOS 표준 마운트용 `smb://` URL 생성
- 공유 이름이 없는 루트와 SMB가 아닌 프로토콜의 mount URL 생성 거부
- 공백 등 경로 문자를 URLComponents로 percent encoding
- username, password, Keychain ID를 mount URL에 포함하지 않음
- 관리 창에서 SMB 프로필을 선택한 경우에만 `Finder에서 연결` 활성화
- NSWorkspace로 Finder 표준 연결 흐름에 전달하여 시스템 인증·마운트 UI 사용

## 검증

- 공백 포함 공유 경로의 scheme·host·decoded path 확인
- URL의 user/password nil, username·Keychain ID 문자열 부재 확인
- FTP 프로필과 공유 없는 SMB 프로필의 명시적 오류 확인
- 전체 Swift Testing 117개 및 FilesMac 빌드 통과
- 한국어/영어 × 라이트/다크 UI 4조합에서 SFTP·SMB 프로필 2개 저장, SMB 연결 명령 활성화와 전체 회귀 통과

## 검증 한계와 남은 항목

- 실제 SMB 서버 인증·마운트·끊김·재연결·파일 작업은 환경 수용 검증이 남아 있다.
- Finder 표준 연결은 앱 Keychain 항목을 직접 전달하지 않으며 시스템 인증 UI를 사용한다.
- FTP/FTPS/SFTP 직접 provider 구현이 남아 있다.

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
