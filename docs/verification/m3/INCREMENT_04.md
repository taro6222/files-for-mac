# M3 네 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 보조 pane의 실제 `NSCollectionView` 그리드 렌더러
- 보조 pane 상세/그리드 전환, 선택 identity, 스크롤 저장, 포커스와 폴더 열기
- 분할 workspace snapshot에 보조 pane 그리드 모드 저장
- 렌더링 중 숨겨진 상세 테이블 delegate가 그리드 선택을 지우는 경쟁 조건 차단
- 데이터 reload에 의한 프로그램적 deselect를 사용자 선택으로 오인하지 않는 알림 억제

## 자동 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 81개 테스트 통과.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-m2-ui.sh
```

결과: 한국어/영어 × 밝게/어둡게 네 조합에서 기존 M2 검사와 다음 M3 검사가 모두 `true`였다.

- `secondaryGridSelection`
- `secondaryGridFolderOpen`
- `secondaryGridSession`

진단 기록에서 요청한 identity, history selection, 실제 그리드 selection이 각 조합에서 동일함을 확인했다.

## 발견 및 수정한 결함

초기 실제 UI 검증에서는 보조 pane에 그리드를 처음 표시할 때 selection이 사라졌다. 숨겨질 상세 테이블의 프로그램적 `selectRowIndexes`가 delegate를 호출하고, 아직 적용되지 않은 빈 그리드 선택을 history에 저장한 것이 원인이었다. 렌더링 중 위치 저장을 차단하고 그리드 내부 reload 선택 알림을 억제해 해결했다.

## 남은 항목

- 그리드 컨텍스트 메뉴와 드래그 앤 드롭
- 목록·컬럼·적응형 전용 렌더러
- 보기별 크기·간격 사용자 지정
- 원본 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
