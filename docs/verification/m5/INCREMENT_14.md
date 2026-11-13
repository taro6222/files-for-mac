# M5 열네 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 원격 연결 프로필 배열을 이름 순으로 JSON 저장하고 원자적으로 교체
- 프로필 파일 POSIX 권한을 소유자 읽기·쓰기 전용(mode 0600)으로 제한
- 읽을 때 프로필을 다시 생성해 손상되었거나 위험한 persisted 입력 재검증
- macOS Security framework generic-password 기반 자격증명 저장·읽기·삭제 어댑터
- 프로필에는 Keychain 항목 ID만 남기고 username label과 secret data는 Keychain에 분리
- 자격증명 항목은 첫 잠금 해제 이후 접근 가능한 정책 사용

## 검증

- 두 프로필 저장 시 이름 순 정렬, JSON 왕복 동일성, mode 0600 확인
- 프로필 파일에 `secret`·`password` 문자열이 없음을 확인
- 비 JSON 파일과 `user@host`가 주입된 persisted 프로필을 거부하는지 확인
- 전체 Swift Testing 116개 통과
- Security framework를 연결한 FilesCore·FilesMac 빌드 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과

## 검증 한계와 남은 항목

- 자동 테스트에서 사용자의 실제 로그인 Keychain에 항목을 생성하지 않았다.
- 서명된 앱 컨텍스트에서 저장·갱신·삭제·재인증 수동 수용 검증이 남아 있다.
- 원격 연결 편집 UI와 프로토콜별 실제 연결·전송 backend가 남아 있다.

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
