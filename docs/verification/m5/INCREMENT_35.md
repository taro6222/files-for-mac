# M5 서른다섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 로컬 `URL`·`FileItem`과 분리된 절대 원격 경로 기반 `RemoteBrowserModel` 추가
- 원격 경로 정규화와 상대 경로·`.`·`..`·제어문자 거부
- 디렉터리 우선 자연 정렬, 뒤로·앞으로·상위 폴더·새로고침·취소 상태 구현
- 탐색 generation과 요청 경로를 함께 검사해 늦게 도착한 이전 목록 폐기
- SFTP 목록을 OpenSSH 지원 `ls -l`로 전환하고 mode 첫 문자로 디렉터리 판정
- 공백·Unicode 이름 보존, 요청 부모의 직접 자식만 허용

## 검증

- 원격 폴더 열기·뒤로·앞으로·상위 폴더와 디렉터리 우선 정렬 확인
- 느린 이전 경로 결과가 새 경로를 덮지 않는지 확인
- 명시적 취소 후 loading 해제·취소 상태 확인
- 공백 포함 OpenSSH long listing의 파일·디렉터리 판정 확인
- `scripts/verify-sftp.sh` 실제 localhost OpenSSH 수용 통과
- 전체 Swift Testing 145개 통과
- 이번 단위는 AppKit UI 코드 변경 없음; 기존 4조합 UI 결과 유지

## 남은 항목

- `RemoteBrowserModel`을 AppKit 원격 탐색 pane에 연결
- 선택 파일 안전 다운로드와 폴더 double-click 동선 통합
- pane 세션 복원과 접근성·키보드 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
