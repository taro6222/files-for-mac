# M3 다섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 양쪽 pane 그리드의 Finder 파일 URL drag source
- 외부 Finder 및 다른 pane에서 들어오는 파일 URL drop destination
- 폴더 아이콘 위 drop은 해당 폴더, 빈 공간 drop은 현재 위치를 대상으로 지정
- Option 복사, Command 이동, 복합 modifier의 안전한 복사 우선 정책 재사용
- 기본·보조 pane 활성화와 안전한 복사/이동 작업 창 연결
- 상세 테이블과 동일한 컨텍스트 메뉴 명령 연결
- 우클릭한 항목을 먼저 선택한 뒤 명령을 실행하는 대상 일관성

## 자동 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 81개 테스트 통과. 기존 `FileDropIntent` modifier 정책 테스트도 유지된다.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-m2-ui.sh
```

결과: 한국어/영어 × 밝게/어둡게 네 조합에서 기존 검사와 다음 연결 검사가 모두 `true`였다.

- `gridContextCommands`
- `gridDragSources`
- `secondaryGridSelection`
- `secondaryGridFolderOpen`
- `secondaryGridSession`

## 남은 항목

- 실제 사람 입력으로 Finder→그리드 및 그리드→Finder drop 결과를 재확인하는 수동 수용 시험
- file promise 기반 지연 제공
- 목록·컬럼·적응형 전용 렌더러
- 보기별 크기·간격 사용자 지정

따라서 M3 완료로 표시하지 않는다.
