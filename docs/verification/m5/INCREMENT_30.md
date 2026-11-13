# M5 서른 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- SFTP 다운로드를 최종 파일과 같은 로컬 디렉터리의 앱 소유 staging 파일로 수신
- staging이 일반 파일이고 심볼릭 링크가 아니며 이름·부모가 계약과 일치할 때만 최종 경로로 publish
- 기존 최종 파일을 교체하지 않고 충돌로 종료하며 실패·취소 시 로컬 staging 정리
- SFTP 업로드를 원격 sibling staging 경로에 전송한 뒤 rename하는 batch 명령으로 구성
- 서버 rename이 기존 목적지를 거부한다는 capability가 검증되기 전에는 업로드 기본 차단
- 업로드 실패 시 원격 staging 삭제를 best-effort로 실행
- 명령 인자·설명에 host·username·원격 경로·개인키 내용을 노출하지 않는 기존 계약 유지

## 검증

- SFTP upload batch가 `put staging` 다음 `rename final` 순서인지 확인
- Unicode·공백 경로 보존과 상대·제어문자 경로 거부 확인
- 로컬 다운로드 staging의 같은 부모·소유 prefix·일반 파일 조건과 링크·외부 staging 거부 확인
- 기존 목적지 보존 및 publish 뒤 staging 제거 확인
- capability 기본값 false와 네트워크/파일 접근 전 업로드 차단 확인
- 전체 Swift Testing 142개 통과
- 한국어/영어 × 라이트/다크 UI 검증 4조합 모두 통과

## 남은 항목

- 실제 localhost sshd에서 rename이 기존 파일을 덮는지 probe하고 서버별 capability를 안전하게 결정
- 실제 SFTP 다운로드·업로드 성공, 연결 중단, 취소, host mismatch 수용 검증
- 전송 진행률·취소 UI와 탐색 pane provider 통합

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
