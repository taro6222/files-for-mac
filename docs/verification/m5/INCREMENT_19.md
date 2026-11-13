# M5 열아홉 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- FTP/FTPS 프로필·Keychain 자격증명·원격 경로를 curl list-only 실행에 연결
- 최대 4MiB 목록 출력과 기본 100,000개 항목 제한
- UTF-8 줄 기반 이름 parsing, CRLF/LF 지원, `.`·`..` 제외
- 부모 경로와 이름을 안정적인 절대 remote locator로 결합
- 잘못된 UTF-8, 이름의 `/`·제어문자, 상대 부모 경로 거부
- 기존 Task 취소가 실행 중 curl 종료로 전파

## 검증

- 일반 파일과 Unicode/공백 폴더의 이름·remote path 확인
- 루트 부모에서 이중 slash 없는 locator 확인
- 잘못된 UTF-8과 `nested/name` 항목 거부 확인
- 최대 1개 설정에서 2개 목록의 listingLimitExceeded 확인
- 전체 Swift Testing 123개 통과
- 한국어/영어 × 라이트/다크 UI 4조합 전체 회귀 통과

## 남은 항목

- MLSD metadata 기반 파일/폴더·크기·날짜·stable ID 확장
- 실제 FTP/FTPS fixture server 인증·TLS·끊김·재시도 수용 검증
- 다운로드 staging/publish와 업로드 부분 파일 정리

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
