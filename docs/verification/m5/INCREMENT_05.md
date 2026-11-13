# M5 다섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 파일 메뉴와 우클릭 메뉴에 `선택 항목을 ZIP으로…` 명령 추가
- 단일 선택은 항목 이름, 다중 선택은 `압축 파일.zip`/`Archive.zip`을 기본 이름으로 제안
- `NSSavePanel`에서 ZIP 대상 경로를 선택하고 기존 안전 생성 provider에 연결
- source 목록, 작업 상태, indeterminate progress, 안전 지점 중단, 완료/실패 상태를 표시하는 AppKit 작업 창
- 작업 중 중복 생성과 창 닫기를 차단하고 완료 후 현재 pane를 새로 고침

## 검증

- FilesMac 빌드 통과
- 전체 Swift Testing 103개 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과
- 각 조합에서 생성 작업 창을 통해 Unicode 파일을 ZIP으로 생성하고 libarchive로 재열어 항목 1개를 확인
- `archiveCreation`, `archiveContextCommands` 검증값과 기존 압축 탐색·추출 회귀 검증 모두 true

## 남은 항목

- 스트림 byte·항목 기반 정량 진행률과 취소 수용 검증
- 보안 규칙 오류의 사용자 친화적 분류·해결 안내
- 암호 ZIP과 7z/RAR capability 표·실행 결과

따라서 M5 완료로 표시하지 않는다.
