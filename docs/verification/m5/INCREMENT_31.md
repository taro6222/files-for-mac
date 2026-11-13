# M5 서른한 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 임시 host/client Ed25519 키와 격리된 설정으로 localhost OpenSSH SFTP fixture 구성
- 실제 OpenSSH의 `sftp>` 프롬프트와 절대 경로 `ls -1` 출력을 안전하게 해석
- 요청한 부모 디렉터리의 직접 자식만 허용하고 다른 부모·중첩·제어문자 출력 거부
- 실제 SFTP 목록과 same-directory staging 다운로드 실행
- 서로 다른 probe 파일 두 개를 올린 뒤 기존 목적지 rename 동작 검사
- rename 거부 시에만 양쪽 원본 내용을 다시 다운로드해 보존 여부를 검증하고 capability 승인
- 성공·실패 경로에서 원격 probe 파일 best-effort 정리

## 검증

- `scripts/verify-sftp.sh` localhost OpenSSH 수용 테스트 통과
- Unicode fixture 목록과 다운로드 내용 `live-fixture` 확인
- 다운로드 뒤 로컬 staging 잔여물 없음 확인
- macOS OpenSSH rename이 기존 목적지를 덮는 동작을 검출하고 capability false 확인
- probe 뒤 원격 `.files-sftp-probe-*` 잔여물 없음 확인
- 전체 Swift Testing 143개 통과
- 한국어/영어 × 라이트/다크 UI 검증 4조합 모두 통과

## 남은 항목

- SFTP 다운로드 대상 선택·진행·취소 UI
- overwrite rename 서버에서 안전 업로드를 제공할 별도 원자적 no-replace 전략 또는 업로드 비활성 안내
- host mismatch·연결 중단·대용량 전송 수용 검증과 탐색 pane provider 통합

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
