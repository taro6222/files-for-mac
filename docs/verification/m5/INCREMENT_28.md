# M5 스물여덟 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- SFTP 개인키를 사용자가 NSOpenPanel에서 명시적으로 선택
- 개인키 전체 경로 문자열 대신 read-only security-scoped bookmark를 프로필에 저장
- bookmark 생성 전 일반 파일이며 심볼릭 링크가 아닌지 확인
- bookmark 해석 때 파일 유형을 다시 검증하고 stale 상태 표시
- 기존 bookmark가 없는 프로필 JSON과의 Codable 호환 유지
- SFTP 프로토콜에서만 개인키 선택 활성화
- 저장·재선택 시 파일 내용이나 개인키 경로를 로그/endpoint에 포함하지 않음

## 검증

- 비 security-scoped test bookmark로 일반 파일 round-trip·표준 경로 동일성·non-stale 확인
- 심볼릭 링크 개인키와 손상 bookmark 거부 확인
- identityBookmark 필드가 없는 기존 persisted 프로필 decode·재검증 통과
- 전체 Swift Testing 138개 통과
- 한국어/영어 × 라이트/다크 UI 4조합에서 SFTP identity 명령 활성화와 SMB 선택 복원 확인

## 남은 항목

- 실제 sandbox/서명 앱 재실행 후 security-scoped bookmark 접근 수용 검증
- stale bookmark 재선택 전 SFTP 연결 차단 안내
- 승인 known_hosts와 identity를 결합한 실제 목록 연결·진행·취소 UI

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
