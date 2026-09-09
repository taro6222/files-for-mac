# M1 다섯 번째 개발 단위 검증

검증일: 2026-09-09. M1 진행 중.

## 변경

- 폴더 열기 실패를 권한 없음, 경로 없음, 폴더가 아닌 항목, 장치/네트워크 연결 불가, 기타 오류로 분류한다. 일반 Cocoa 오류에 포함된 POSIX 원인도 최대 8단계까지 확인한다.
- 오류 본문과 복구 안내를 한국어/영어로 제공한다. 시스템의 `localizedDescription`에 의존하던 한국어 화면의 영어 본문을 제거했다. 알 수 없는 오류도 선택된 앱 언어로 안내한다. 원래 진단 문자열은 모델에 유지하며 화면에는 표시하지 않는다.
- 일반 파일을 폴더로 열면 `ENOTDIR`로 구분한다. 새로고침 성공·홈 이동 시 분류된 오류를 초기화한다.
- 독립 테스트 설정을 공유하는 두 BrowserWindow의 반복 탐색과 설정 동기화 검증을 추가했다.

## 검증 범위

- Swift Testing 23개: 기존 21개와 래핑 오류 분류, 실제 누락 폴더 생성 후 복구·일반 파일 경로 오류·홈 초기화 테스트.
- UI: 한국어/영어 × 밝음/어두움, 조합당 14개 검사. 기존 10개와 오류 본문 현지화, 다중 창 5회 반복, 닫힌 창 객체 해제, 남은 창 사용 가능 여부.
- 각 반복은 숨김 항목·확장자 옵션을 전환하고 실제 셀 문자열을 확인한다. 두 창은 서로 다른 폴더를 유지하며, 첫 창은 10,001개 항목에서 홈/뒤로 탐색 후 선택을 복원한다. 작은 두 번째 폴더는 숨김 설정에 따라 1개 또는 2개 항목을 표시한다.
- 새 설정 suite, 창/열/사이드바 자동 저장 비활성화를 사용한다. 사용자의 앱 설정과 원본 파일을 변경하지 않는다.
- 권한 오류 PNG에서 한국어 본문과 배치를 직접 확인했다. OS 오류 진단 원문 전체 현지화가 아니라 앱의 오류 분류별 안내다.

## 재현과 결과

Swift Testing 23개와 UI 56개 검사가 모두 통과했다. Swift release 앱 빌드·서명 검증 및 Xcode Debug 빌드도 통과했다. 4조합의 5회 다중 창 주기 시간은 1.626~1.774초 범위였다.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox
scripts/verify-ui.sh
scripts/build-app.sh
xcodebuild -project FilesMac.xcodeproj -scheme 'Files macOS' -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

환경: macOS 26.6.2 (25G83), Apple Silicon, Swift 6.3.3. 최종 결과는 [increment-05](increment-05/)의 조합별 JSON에 보관한다. 한국어 권한 오류 기준 이미지는 `ko-light-permission.png`다. 빌드 산출물과 나머지 실행 이미지는 Git에서 제외한 `build/ui-verification/`에 저장한다.

`multiwindowCycleMinimumSeconds`와 `multiwindowCycleMaximumSeconds`는 설정 갱신·두 목록 로드·홈/뒤로 탐색을 모두 포함하는 5회 표본의 최솟값/최댓값이다. 단일 파일 목록 성능, p95, 장시간 안정성 결과로 해석하지 않는다. 표시 시간은 이전 단위와 동일하게 AppKit layout/display 기준이며 compositor 측정이 아니다.

## 남은 항목

VoiceOver 음성·전체 실제 키 입력, TCC, 연속 스크롤 FPS·반복 p95·장시간 실행, Windows 원본 대조, macOS 14/Intel와 실제 네트워크 볼륨 시험은 미완료다. 연결 불가 분류는 합성 POSIX 오류로 단위 검증했으며 실제 네트워크 단절 검증이 아니다. M2는 아직 시작하지 않았다.
