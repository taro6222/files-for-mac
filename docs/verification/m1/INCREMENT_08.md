# M1 여덟 번째 개발 단위 검증

검증일: 2026-09-09. M1 진행 중.

## 변경

- 폴더 열기 실패·읽기 중단 안내 아래에 `다시 시도`와 `폴더 선택…`을 제공한다. 사용자가 복구 방법을 찾기 위해 도구 모음이나 메뉴로 이동할 필요를 줄였다.
- `다시 시도`는 현재 위치를 다시 읽는다. `폴더 선택…`은 파일 선택을 허용하지 않는 시스템 NSOpenPanel을 연다. 확인한 URL만 탐색하며 취소하면 현재 위치를 유지한다.
- 권한 오류에서 폴더 선택창은 사용자가 직접 위치를 선택하도록 안내하고, 파일 시스템의 읽기 권한은 별도로 필요함을 명시한다. POSIX 권한 변경, TCC 자동 변경, 관리자 권한 상승을 수행하지 않는다.
- 복구 버튼은 로딩·정상 목록·정상 빈 폴더·홈에서 숨긴다. 부분 목록이 있는 중단 상태는 목록을 가리지 않고 기존 도구 모음 재시도를 유지한다.

## 검증

UI 행렬은 한국어/영어 × 밝음/어두움의 조합별 23개 검사다. 기존 20개와 오류 화면 재시도, 권한 오류 복구 버튼 표시, 중단 화면 복구 버튼 표시를 검증한다. 중단 화면의 실제 `다시 시도` 버튼을 실행해 로드 성공 시 복구 버튼이 사라지는 것도 확인한다.

한국어 밝은 테마의 권한 오류에서 두 버튼의 배치와 문구를 AppKit 이미지로 확인했다. 자동화된 모델/UI 검사와 실제 시스템 폴더 선택창 검증은 구분한다.

재현:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox -Xswiftc -gnone
scripts/verify-ui.sh
scripts/build-app.sh
xcodebuild -project FilesMac.xcodeproj -scheme 'Files macOS' -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT=dwarf build
```

환경: macOS 26.6.2 (25G83), Apple Silicon, Swift 6.3.3. dSYM 관련 검증 빌드 제한은 이전 단위와 같다.

## 남은 항목

시스템의 접근 정책과 파일 권한은 환경별 검증이 필요하다. NSOpenPanel로 선택했다는 사실만으로 모든 경로의 접근 성공 또는 재실행 후 접근 유지가 보장되지는 않는다. App Sandbox 미사용 개발 버전이며 security-scoped bookmark 기반 복원은 구현하지 않았다. VoiceOver·최소 macOS/Intel·네트워크 볼륨·Windows 원본 대조·장시간 검증은 남아 있다.

## 실제 시스템 선택창 확인

별도 bundle ID의 `Files Keyboard QA.app`에서 없는 임시 폴더 경로를 열어 오류 화면을 만들었다. 오류 화면의 `폴더 선택…` 버튼으로 NSOpenPanel을 열고 Cancel을 눌렀을 때 원래 경로와 오류 화면이 유지되는 것을 확인했다.

다시 선택창을 열어 ⇧⌘G로 `build/keyboard-fixture`를 지정하고 열기를 확인했다. 이전 단위에서 직접 경로 입력 시 읽기가 대기하던 동일 프로젝트 fixture의 `child`와 `readme.txt` 두 항목이 표시됐다. ⌘R 수동 새로고침 후에도 두 항목을 유지했다. 자동 갱신 상태는 계속 `사용 불가`였으므로 FSEvents 접근까지 복구됐다고 보지 않는다. 검증 앱은 종료했다. TCC 데이터베이스나 시스템 설정을 수정하지 않았으며, 재실행 후 접근 유지 여부는 이번에 검증하지 않았다.

## 최종 결과

코어 25개와 UI 92개(23×4) 검사, release 앱 빌드·서명 검증 및 Xcode Debug 빌드가 통과했다. [조합별 원본](increment-08/)과 한국어 복구 화면을 보관했다. 이번 검증으로 특정 폴더를 시스템 선택창에서 선택한 뒤 목록 읽기와 수동 새로고침이 성공한 것은 확인했지만, 파일 시스템 대기의 모든 원인을 확정한 것은 아니다.
