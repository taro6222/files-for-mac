# M5 서른아홉 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 원격 목록에서 Return·keypad Enter로 선택 항목 활성화
- 선택 폴더는 탐색, 선택 파일은 기존 안전 다운로드 동선 호출
- Escape를 진행 중 원격 목록 취소에 연결
- Delete·Forward Delete를 원격 삭제로 연결하지 않고 비파괴 beep 처리
- 원격 경로·파일 목록·탐색 상태에 한국어/영어 VoiceOver label 부여
- 폴더에서는 다운로드 control 비활성, 파일에서만 활성 유지

## 검증

- 한국어/영어 × 라이트/다크 UI 4조합 모두 통과
- Enter 기반 폴더 열기와 파일 다운로드 callback 확인
- `remoteBrowserAccessibility`에서 경로·목록·상태 label 확인
- 원격 삭제 action이 없고 파일 선택 상태만 다운로드를 활성화하는지 확인
- FilesMac DEBUG 빌드 통과
- 기존 전체 Swift Testing 146개 결과 유지; 이번 단위는 FilesCore 변경 없음

## 남은 항목

- 실제 VoiceOver 실행으로 role·selection announcement 청취 확인
- 실제 키보드 이벤트와 focus ring 수동 수용
- FTP/FTPS 연결 UI와 FTPS TLS 수용 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
