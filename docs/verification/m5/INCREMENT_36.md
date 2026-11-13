# M5 서른여섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- SFTP 목록 연결 성공 요약 alert를 실제 AppKit 원격 탐색 pane으로 교체
- 이름·종류 열과 디렉터리 우선 목록 표시
- 폴더 double-click, 뒤로·앞으로·상위 폴더·새로고침·중단 연결
- loading·취소·오류·항목 수 상태 표시와 작업 중 control 비활성화
- 파일 선택 시에만 다운로드 활성화
- 선택 다운로드를 기존 no-replace staging/publish와 전송 취소 UI에 연결
- 각 원격 목록 요청 동안 security-scoped identity 접근을 열고 반드시 종료
- 다운로드 sheet와 진행 결과를 작업을 시작한 원격 pane에 표시

## 검증

- FilesMac 빌드 통과
- 전체 Swift Testing 145개 통과
- 한국어/영어 × 라이트/다크 UI 4조합 회귀 통과
- 기존 원격 연결 준비 gate·SMB·SFTP 다운로드 gate와 최소 창 레이아웃 통과

## 남은 항목

- fixture 기반 원격 pane 자체의 폴더 double-click·navigation·선택 다운로드 UI 수용 검증
- 원격 pane 경로·창 상태 세션 보존
- VoiceOver·키보드 전용 흐름 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
