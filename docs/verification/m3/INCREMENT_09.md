# M3 아홉 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 보기 옵션의 작게·보통·크게 프리셋과 선택 상태 표시
- 그리드 아이콘·셀 크기·가로/세로 간격 동시 조절
- 단일열 목록 행 높이 조절
- 같은 창의 기본·보조 pane 및 다른 창에 동기 반영
- UserDefaults 저장과 재실행 복원
- 알 수 없는 저장값을 보통 크기로 안전 복구

## 자동 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 84개 테스트 통과.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-m2-ui.sh
```

결과: 한국어/영어 × 밝게/어둡게 네 조합에서 `largeViewSizeApplied`, `secondaryViewSizeApplied`를 포함한 모든 검사가 `true`였다. 크게 프리셋은 그리드 142×124pt·목록 행 38pt, 작게 프리셋은 그리드 96×84pt·목록 행 26pt로 실제 레이아웃에 반영됐다.

## 남은 항목

- 컬럼 보기의 컨텍스트 메뉴와 Finder/다른 pane 드래그 앤 드롭
- 폴더별 보기 설정과 전체 폴더 동기화의 원본 동작 대조
- 명령 팔레트·단축키 재지정·툴바 사용자 지정 등 M3 후속 범위
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
