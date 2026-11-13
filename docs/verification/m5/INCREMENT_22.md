# M5 스물두 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 외부 서버나 사용자 계정 없이 localhost 전용 FTP fixture server 실행
- 임시 root·동적 loopback port·전용 임시 자격증명 사용
- `FILES_TEST_FTP_*` 환경이 있을 때만 실제 네트워크 테스트 강제 실행
- 실제 `/usr/bin/curl` subprocess로 목록과 Unicode 파일 다운로드
- 다운로드 내용 및 로컬 staging 잔존 없음 확인
- 종료 시 server process와 `/tmp` fixture root 정리

## 검증

- `/tmp` 가상환경의 pyftpdlib 2.2.0을 사용했으며 저장소 산출물에는 포함하지 않음
- `PYFTPDLIB_PYTHON=/tmp/files-ftp-venv/bin/python3 scripts/verify-ftp.sh` 통과
- 실제 목록에서 `fixture-한글.txt` 확인
- 실제 다운로드 내용 `live-fixture` 일치 및 `.files-download-*` 잔존 0개 확인
- 강제 실제 서버 테스트 1개 통과, 전체 Swift Testing 128개 통과
- 한국어/영어 × 라이트/다크 UI 4조합 전체 회귀 통과

## 남은 항목

- pyftpdlib는 검증용 선택 의존성이며 설치 방법·버전 고정 정리 필요
- FTPS 인증서 검증 fixture와 네트워크 단절·취소 수용 검증
- 실제 업로드·RNTO 기존 대상 동작 probe 및 capability 발급

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
