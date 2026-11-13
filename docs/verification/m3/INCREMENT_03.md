# M3 세 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 기본 pane의 실제 `NSCollectionView` 그리드 렌더러
- 파일·폴더 시스템 아이콘, 두 줄 이름, 다중 선택 시각 상태
- 상세 보기와 그리드 보기 간 선택 identity 및 스크롤 상태 공유
- 그리드 키보드 포커스, 폴더 열기, 뒤로 이동 후 보기 모드 유지
- 선택 기반 파일 작업과 Finder에서 보기 대상 연결
- 10,000항목 fixture의 한국어/영어 × 밝게/어둡게 실제 AppKit 화면 검증

## 자동 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 81개 테스트 통과.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh
```

결과: 다음 네 조합의 `report.json`에서 모든 검사가 `true`였다.

- 한국어·밝게
- 한국어·어둡게
- 영어·밝게
- 영어·어둡게

이번 단위에서 추가된 실제 앱 검사:

- `gridVisible`
- `gridSelectionIdentity`
- `gridFocus`
- `gridFolderOpen`
- `gridModeRestoredAfterNavigation`

각 조합에 `files-grid.png` 화면 증거를 생성해 레이아웃, 선택 표시, 긴 이름 생략, 다크 모드 대비를 확인했다. 생성물은 빌드 증거이며 소스 커밋에는 포함하지 않는다.

## 남은 항목

- 보조 pane 그리드 렌더러
- 그리드 컨텍스트 메뉴와 Finder/다른 pane 드래그 앤 드롭
- 목록·컬럼·적응형 전용 렌더러
- 원본 Windows 화면과의 정량 시각 대조

따라서 M3 완료로 표시하지 않는다.
