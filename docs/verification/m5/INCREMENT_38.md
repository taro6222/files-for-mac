# M5 서른여덟 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 프로필 UUID별 마지막 원격 절대 경로 저장·복원
- 원격 경로를 저장 전 정규화하고 상대 경로·상위 경로 탈출·제어문자 거부
- Application Support의 별도 JSON을 staging·fsync·atomic replace로 publish
- 세션 JSON 권한을 매 저장 후 0600으로 강제
- 프로필 삭제 시 해당 원격 경로 상태 제거
- 프로필 UUID 기반 AppKit frame autosave name으로 pane 크기·위치 복원
- 원격 pane 경로가 바뀔 때 세션을 저장하고 재연결 시작 경로로 사용

## 검증

- 두 프로필 경로 독립 저장·복원과 중복 slash 정규화 확인
- 안전하지 않은 `..` 경로 저장 거부 확인
- 세션 파일 POSIX 0600과 staging 잔여물 없음 확인
- 한 프로필 제거 뒤 다른 프로필 상태 보존 확인
- 전체 Swift Testing 146개 통과
- 한국어/영어 × 라이트/다크 UI 4조합 원격 pane fixture 및 기존 회귀 통과

## 남은 항목

- 키보드 Enter 폴더 열기·파일 다운로드와 Escape 중단
- VoiceOver label·role·selection announcement 검증
- 실제 재실행을 포함한 frame 복원 수동 수용

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
