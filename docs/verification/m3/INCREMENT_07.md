# M3 일곱 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 폴더 선택 시 다음 열을 비동기로 여는 네이티브 계층형 컬럼 렌더러
- 기본·보조 pane의 컬럼 전환, 선택 identity, 키보드 포커스와 세션 보존
- 오른쪽 방향키의 하위 폴더 확장과 왼쪽 방향키의 상위 열 복귀
- 이중 클릭·Enter 명령 경로의 파일/폴더 열기
- 숨김 항목 및 현재 정렬 순서를 새로 연 하위 열에 적용
- 뒤로 이동 후 컬럼 보기 모드 복원

## 자동 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 81개 테스트 통과.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-m2-ui.sh
```

결과: 한국어/영어 × 밝게/어둡게 네 조합에서 다음 항목을 포함한 모든 검사가 `true`였다.

- `columnsVisible`
- `columnsHierarchy`
- `columnsFocus`
- `columnsLeftNavigation`
- `columnsFolderOpen`
- `columnsModeRestoredAfterNavigation`
- `secondaryColumnsHierarchy`
- `secondaryColumnsSession`

각 기본 pane 조합의 `files-columns.png`를 생성했다. 한국어 라이트 모드 캡처를 직접 확인해 컬럼 구분, 선택 행, 폴더 disclosure, 툴바 모드 표시가 정상임을 확인했다.

## 남은 항목

- 적응형 보기 정책
- 컬럼 보기의 컨텍스트 메뉴와 Finder/다른 pane 드래그 앤 드롭
- 목록/그리드 크기·간격 사용자 지정과 저장
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
