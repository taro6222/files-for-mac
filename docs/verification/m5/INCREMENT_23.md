# M5 스물세 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 서버별 기존 대상 비대체 RNTO capability를 실제 mutation probe로 판정
- 무작위 A/B 원격 파일 업로드 후 A→B rename 시도
- rename 거부 시 A/B를 다시 다운로드하여 두 내용이 모두 보존됐을 때만 capability true
- rename 성공 시 서버가 기존 대상을 덮어쓸 수 있으므로 capability false
- 성공·거부·오류 모든 경로에서 DELE cleanup 시도
- curl quote 명령이 실제 전송되도록 rename/delete 후 list-only 수행

## 검증

- localhost pyftpdlib 2.2.0에서 RNTO가 기존 B를 덮어씀을 실제 확인
- `renameRefusesExistingDestination == false` 판정으로 안전 업로드 계속 차단
- probe 종료 후 `.files-probe-*` 항목 0개 확인
- `no-body` 조합이 quote를 전송하지 않는 현상을 발견해 list-only 방식으로 수정
- 실제 localhost 강제 테스트 통과, 전체 Swift Testing 128개 통과
- 한국어/영어 × 라이트/다크 UI 4조합 전체 회귀 통과

## 남은 항목

- 기존 대상 비대체 RNTO를 제공하는 서버 fixture의 capability true 및 실제 업로드 검증
- probe 네트워크 단절 시 cleanup 재시도/잔존 항목 진단
- FTPS TLS fixture와 SFTP 구현

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
