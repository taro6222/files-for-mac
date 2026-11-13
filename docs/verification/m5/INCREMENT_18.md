# M5 열여덟 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 인자 배열과 표준입력을 사용하는 공통 원격 subprocess executor
- stdout·stderr를 동시에 비워 pipe 교착 방지
- 실행 파일 시작 실패와 non-zero 종료 상태의 구조화된 오류
- 기본 4MiB 합산 출력 한도
- Swift Task 취소 시 실행 중 Process 종료 및 CancellationError 전달
- blocking Process 대기는 detached 동기 helper에 격리해 main actor 비차단

## 검증

- `/bin/cat`에 표준입력 전달 후 stdout 동일성, 빈 stderr, 종료 상태 0 확인
- `/usr/bin/false` 종료 상태 1 오류 확인
- 제한보다 큰 printf 출력의 outputLimitExceeded 확인
- 5초 sleep을 50ms 후 취소하여 조기 종료와 CancellationError 확인
- 전체 Swift Testing 122개 통과
- 한국어/영어 × 라이트/다크 UI 4조합 전체 회귀 통과

## 남은 항목

- 실행 중 누적 출력이 한도를 넘는 즉시 프로세스를 종료하는 streaming hard cap
- FTP/FTPS 목록 parsing, 다운로드 staging/publish, 업로드 부분 파일 정리
- 실제 FTP/FTPS 서버의 인증·TLS·끊김·재시도 수용 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
