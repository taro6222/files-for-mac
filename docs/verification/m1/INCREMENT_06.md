# M1 여섯 번째 개발 단위 검증

검증일: 2026-09-09. M1 진행 중.

## 발견과 수정

실제 키보드로 테스트 폴더 경로를 제출한 뒤 앱 응답이 멈췄다. 해당 앱의 스택 샘플은 메인 스레드의 `BrowserWindow.updateWatcher → DirectoryWatcher.init → FSEventStreamCreate → open` 대기를 보여 주었다. 감시 등록과 해제를 백그라운드로 옮겼다. 취소되거나 경로가 달라진 뒤 생성된 감시기는 연결하지 않고 해제한다. 등록 전 파일 변경을 놓치지 않도록 등록 직후 다시 읽는다.

비동기 감시 등록을 넣은 반복 검사에서 히스토리 선택·스크롤 복원 실패도 발견했다. 로딩 중인 부분 목록에는 원래 선택 항목이 없을 수 있으므로 자동 위치 저장이 기존 선택을 덮어쓰지 않게 했다. 사용자의 실제 선택 변경은 별도로 저장한다. 예약된 자동 갱신은 실행 직전 경로와 로딩 상태를 다시 확인한다.

## 자동 검증

- 기본 UI 행렬: 한국어/영어 × 밝음/어두움, 각 17개 검사. 기존 검사에 100개 스크롤 위치, 0.5초 지연 감시 생성 중 탐색 응답, 늦게 완료된 감시 등록 폐기를 추가했다.
- 다중 창 반복은 각 조건별 결과도 JSON에 기록한다. 항목 수, 확장자 셀, 두 창 선택, 위치, 뒤로 탐색 후 선택·항목 수를 각각 확인한다.
- `scripts/verify-ui.sh --performance`: 한국어/어두움에서 20회 다중 창 탐색과 100개 스크롤 위치를 측정한다. 원시 표본과 nearest-rank p95를 함께 저장한다.
- 테스트 프로세스는 180초 제한을 두고 실패 시 비정상 종료한다. 이전 report.json을 지워 오래된 성공 결과가 남지 않게 했다.

## 측정의 의미

다중 창 주기는 숨김/확장자 설정 갱신과 두 폴더 읽기, 홈/뒤로 탐색을 포함한다. 스크롤 표본은 전체 목록에서 순서대로 분산된 100개 행으로 `scrollRowToVisible`을 호출하고 AppKit layout/display까지의 시간을 측정한다. 입력 이벤트 기반 연속 스크롤 FPS나 compositor의 실제 화면 표시 시간이 아니다. DEBUG·최적화 없음, 로컬 warm fixture 기준이며 p95도 이 실행의 표본에만 해당한다.

## 빌드 환경

macOS 26.6.2 (25G83), Apple Silicon, Swift 6.3.3. 이번 실행에서는 `dsymutil`이 `_CFIterateDirectory → open`에서 대기하는 현상이 재현되었다. 해당 검증 빌드만 중단하고 UI/코어 검증은 `-Xswiftc -gnone`, Xcode는 `DEBUG_INFORMATION_FORMAT=dwarf`로 실행했다. DEBUG 코드와 최적화 수준은 유지하며 dSYM만 생성하지 않는다. 일반 dSYM 빌드가 복구되었다고 주장하지 않는다.

재현:

```sh
scripts/verify-ui.sh
scripts/verify-ui.sh --performance
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox -Xswiftc -gnone
scripts/build-app.sh
xcodebuild -project FilesMac.xcodeproj -scheme 'Files macOS' -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT=dwarf build
```

## 남은 항목

VoiceOver 음성·TCC·실제 연속 스크롤·장시간 실행·Windows 원본·macOS 14/Intel·실제 네트워크 볼륨 검증은 남아 있다. OS의 파일 시스템 호출 자체는 취소할 수 없으므로, 취소된 감시 생성은 호출이 반환된 뒤 해제한다. 메인 스레드 분리는 네트워크 볼륨의 모든 대기 문제를 해결했다는 의미가 아니다.

## 실제 키보드 확인

수정된 release 앱을 CUA로 조작했다. Desktop의 `build/keyboard-fixture`는 읽기 대기가 계속되었지만 ⇧⌘H로 홈 이동이 즉시 성공했다. 이 경로의 OS 파일 시스템 대기 원인(TCC 등)은 확정하지 않았다.

독립 `/private/tmp/files-keyboard-qa-20260909`에서는 ⌘L·경로·Return으로 2개 항목을 읽고 목록 초점을 확인했다. ↓·⌘↓로 child 폴더 열기, ⌘[로 돌아와 child 선택 복원, ⌘A로 2개 전체 선택, ⌃⌘S·↓로 사이드바 즐겨찾기 초점, ⇧⌘H로 홈 이동을 확인했다. 이는 실제 키 입력 검증이며 VoiceOver 음성 검증은 아니다. 마지막에 앱을 종료했다.

## 최종 결과

- 코어 23개, 기본 UI 행렬 68개(17×4), 성능 실행의 검사 17개 모두 통과했다. 지연 등록·취소 검사도 포함한다.
- release 앱 빌드·서명 검증과 `DEBUG_INFORMATION_FORMAT=dwarf` Xcode Debug 빌드가 통과했다.
- [성능 원본](increment-06/performance.json): 20회 다중 창 주기 최소 1.537초, 최대 1.729초, p95 1.717초. 100개 스크롤 위치의 AppKit 처리 p95 2.924ms.
- 같은 실행에서 최초 비어 있지 않은 AppKit 표시 68.113ms, 전체 표시 966.052ms. 실제 compositor 첫 frame 측정과는 다르다.
- 기본 행렬 원본은 [한국어 밝음](increment-06/ko-light.json), [한국어 어두움](increment-06/ko-dark.json), [영어 밝음](increment-06/en-light.json), [영어 어두움](increment-06/en-dark.json)에 보관했다.
