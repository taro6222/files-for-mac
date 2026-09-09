# M1 개발 프리뷰 검증 기록

검증일: 2026-09-09 · 판정: 첫 구현 단위 통과, M1 전체 게이트는 진행 중

## 빌드

- SwiftPM debug build: 통과.
- SwiftPM release build + .app 번들 + ad-hoc codesign: 통과.
- Xcode `Files macOS` scheme debug build, CODE_SIGNING_ALLOWED=NO: 통과.
- 장비: arm64, macOS 26.6.2, Xcode 26.6, Swift 6.3.3.
- 배포 최소 OS 14 및 Intel에서 실제 실행한 결과는 없음.

## 자동 테스트

명령: `CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox`

| 테스트 | 결과 |
|---|---|
| listingHiddenFilesAndMetadata | 통과: 숨김 필터, 크기, 폴더 판별 |
| missingDirectoryThrows | 통과: 없는 경로를 성공으로 반환하지 않음 |
| hardLinksRemainSeparateEntries | 통과: hard link 두 항목 ID 중복 없음 |
| historyPreservesSelectionAndDropsForwardBranch | 통과: 선택·스크롤 복원과 분기 처리 |
| sortingKeepsFoldersFirstAndNaturalNames | 통과: 폴더 우선 및 자연 정렬 |
| staleResultsNeverReplaceNewLocation | 통과: 취소를 무시하는 느린 loader도 새 화면을 덮지 못함 |
| failedLoadIsNotEmptySuccess | 통과: 오류 상태와 빈 폴더 상태 구별 |
| tenThousandEntries | 통과: 10,000개 실제 fixture 열거 |

Swift Testing 결과는 8개 모두 통과다. XCTest 호환 runner가 먼저 출력하는 '0 tests'와 혼동하지 않는다.

최종 코어 테스트 측정의 10,000개 전체 열거는 0.486474708초였다. 단일 실행이며 p95, 콜드 캐시, 첫 화면 표시 및 스크롤 성능을 입증하지 않는다. 테스트 fixture는 실행 후 제거했다.

첫 실행에서는 localizedTypeDescription 부가 조회 실패가 전체 metadata를 unknown으로 바꾸는 문제를 검출했다. 필수 metadata와 분리해 종류는 현재 폴더/확장자로 표시하도록 수정한 후 재검증했다.

## 실제 앱 창

CUA로 로컬 .app 실행과 접근성 트리/스크린샷을 확인했다.

- 홈, 실제 로컬 폴더 상세 목록, 이름·날짜·종류·크기 표시 확인.
- 프로젝트 경로 입력 후 폴더 탐색과 항목 선택 상태 확인.
- 한국어 및 현재 시스템의 어두운 테마 확인.
- 사이드바가 아래로 밀리는 배치와 버튼 아이콘/제목 겹침을 수정하고 재실행하여 확인.
- 파일 쓰기 동작은 구현되지 않았으며 UI 검증에서도 실행하지 않음.

이 기록은 전체 UI 자동화 완료가 아니다. Windows 기준 캡처, 밝은 테마·영어·VoiceOver·최소 창 크기 전수 검증 및 fixture 기반 이미지 파일 보관은 남아 있다. 개인 파일 목록이 포함된 확인 화면은 저장소에 저장하지 않았다.

## 현재 제한

전체 항목 로딩 뒤 정렬/표시하는 초기 버전이다. provider 배치 전달, 안정적인 파일 identity, 세밀한 watcher, 경로 자동 완성 등은 DEVELOPMENT_STATUS.md에 추적한다. 서명은 개발용이며 공증·DMG 배포는 아직 수행하지 않았다.
