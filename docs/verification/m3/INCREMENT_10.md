# M3 열 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 컬럼 행 우클릭 시 해당 항목 선택과 기존 파일 작업 컨텍스트 메뉴 제공
- 각 열의 파일 URL 드래그 소스
- 폴더 행 및 열의 현재 위치를 드롭 대상으로 구분
- Option 복사·Command 이동 의도를 기존 안전 복사/이동 엔진에 전달
- 기본·보조 pane의 활성화 및 명령 대상 라우팅

## 자동 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 84개 테스트 통과.

`DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-m2-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 `columnContextCommands`, `columnDragSources`를 포함한 모든 검사가 `true`였다.

## 남은 항목

- 외부 앱 file promise 수신
- 폴더별 보기 설정과 전체 폴더 동기화의 원본 동작 대조
- 명령 팔레트·단축키 재지정·툴바 사용자 지정 등 M3 후속 범위
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
