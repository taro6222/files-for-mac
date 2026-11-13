# M3 여섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 상세 열 보기와 구분되는 아이콘+이름 중심의 네이티브 단일열 목록 렌더러
- 기본·보조 pane의 목록 전환, 다중 선택, identity/스크롤 저장, 키보드 포커스
- 더블클릭·Enter 명령 경로의 파일/폴더 열기
- 컨텍스트 메뉴와 Finder/다른 pane 드래그 앤 드롭
- 파일 작업 대상과 workspace session 보기 모드 보존
- 선택 행을 색상 외 행 형태와 충분한 강조로 표시

## 자동 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 81개 테스트 통과.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-m2-ui.sh
```

결과: 한국어/영어 × 밝게/어둡게 네 조합에서 다음 항목을 포함한 모든 검사가 `true`였다.

- `listVisible`
- `listSelectionIdentity`
- `listFocus`
- `listFolderOpen`
- `listModeRestoredAfterNavigation`
- `secondaryListSelection`
- `secondaryListFolderOpen`
- `secondaryListSession`

각 기본 pane 조합의 `files-list.png`를 생성했다. 한국어 다크 모드 캡처를 직접 확인해 10,000항목, 긴 유니코드 이름, 아이콘, 선택 행 강조, 툴바 모드 표시가 정상임을 확인했다.

## 남은 항목

- 컬럼 보기의 계층별 렌더러와 키보드 탐색
- 적응형 보기 정책
- 목록/그리드 크기·간격 사용자 지정과 저장
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
