# M3 열한 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 메인 메뉴의 모든 leaf 명령을 자동 인덱싱하는 단일 명령 카탈로그
- 메뉴와 동일한 selector·target·`validateMenuItem` 활성 조건 사용
- 카테고리·명령명 다국어 부분 검색과 발음 구별 부호 비민감 검색
- 현재 단축키 표시와 비활성 명령의 실행 차단 안내
- 검색 필드에서 위/아래·Return·Esc로 완전한 키보드 조작
- ⇧⌘P 진입 단축키와 접근성 검색 레이블

## 자동 및 실제 UI 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 84개 테스트 통과.

`DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 다음 검사가 모두 `true`였다.

- `commandPaletteIndexesMenus`
- `commandPaletteStableIDs`
- `commandPaletteSearch`
- `commandPaletteWindow`

각 조합의 `command-palette.png`를 생성했다. 한국어 다크 캡처를 직접 확인해 검색어, 카테고리, 명령명, 단축키, 결과 수와 대비가 표시됨을 확인했다.

## 남은 항목

- 사용자 단축키 재지정·충돌 검사·기본값 복원
- 툴바 표시·순서·overflow 사용자 지정
- 테마·재질 및 폴더별 보기 설정의 원본 동작 대조
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
