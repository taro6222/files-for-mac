# M5 스물아홉 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- SFTP 프로필·사용자 이름·identity bookmark·승인 known_hosts를 하나의 준비 gate로 결합
- 프로토콜, 사용자, identity 존재·non-stale·일반 파일, trust 일반 파일을 실행 전 검사
- 준비 gate를 통과한 SFTP 프로필에서만 목록 연결 버튼 활성화
- 연결 동안 security-scoped identity 접근 시작·종료
- strict private config executor와 SFTP 목록 provider 실행
- 성공 시 전체 항목 수와 처음 8개 이름 표시
- 실패 시 성공처럼 표시하지 않고 오류 sheet 및 버튼 상태 복구

## 검증

- 정상 profile/bookmark/trust에서 key configuration 생성 확인
- identity 누락, 사용자 누락, trust 누락 각각 명시적 차단 확인
- 전체 Swift Testing 139개 통과
- 한국어/영어 × 라이트/다크 UI 4조합에서 미준비 QA SFTP 연결 비활성 확인
- 기존 SFTP trust·identity 명령과 SMB Finder 연결 활성 상태 복원 확인

## 남은 항목

- 실제 localhost sshd에서 준비 gate 통과·목록 성공·host mismatch 실패 수용 검증
- SFTP 다운로드·업로드 staging/publish 및 진행·취소 UI
- 연결 결과를 탐색 pane provider로 통합

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
