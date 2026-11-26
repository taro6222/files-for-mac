# M7 Increment 349 — 번들 SDK의 native 런타임 resolver

상태: Core resolver 구현·ARM 검증 완료. 실제 UI 선택/호출·배치별 게시·최신 두 CPU resolver·정식 배포 수용은 미완료다.

## 구현

SevenZipArchiveProvider.bundled(in:timeout:)는 지정한 앱 또는 Bundle.main에서 SDK를 찾는다. 고정된 Helpers/SevenZipWorker와 Frameworks/7z.so 경로만 반환한다. Python·shell·PATH 탐색·환경 변수로 다른 실행 파일을 선택하지 않는다. 명시적인 executable/library initializer는 기존 integration 도구용으로 유지하며 앱 연결에서는 새 factory를 사용하도록 한다.

native Security API로 앱과 두 구성 요소의 모든 architecture 서명을 strict 검증한다. 코드 메타데이터는 현재 프로세스 CPU로 조회해 유니버설 파일의 다른 slice와 혼동하지 않게 한다. 앱의 signature identifier는 Info.plist와 맞아야 하고 두 구성 요소는 각 역할 identifier를 가져야 한다. 개발 preview에서만 ad-hoc/Team 없음 조합을 허용한다. non-ad-hoc과 stable은 Apple Developer ID Application requirement와 동일한 Team을 요구한다. Team 문자열은 10자리 영대문자/숫자만 허용한다. ad-hoc preview 검사는 배포자 신원 증명이 아니다.

현재 실행 중인 앱 자체를 선택할 때는 SecCodeCopySelf/SecCodeCheckValidity로 실행 호스트도 선택한 앱의 designated requirement를 만족하는지 확인한다. 서명된 다른 helper의 requirement를 현재 test host가 만족하지 않는 것도 검증했다. 서명 없는 개발 test runner는 identity 확인에서 거부되는 경로를 별도로 검사하도록 한다.

manifest는 최대 1MiB이며 타입·version·고정 SDK/source pin·CPU 목록·정확한 파일 집합·빌드 입력과 hash 형식을 검사한다. CryptoKit의 streaming SHA-256으로 코드/자료 hash와 제공된 helper/recipe 및 원본 source archive pin을 대조한다. code/resource별 읽기는 최대 64MiB, Info/manifest는 1MiB로 제한한다. 이 수치는 SDK가 아카이브를 해독할 때의 메모리 제한을 대신하지 않는다.

앱 root FD를 열고 openat/O_NOFOLLOW로 구성 요소를 따라 읽는다. regular file인지 확인하고 FIFO에는 비차단으로 접근해 즉시 거부한다. 파일/디렉터리 추가·symlink·누락·잘못된 경로를 거부한다. root와 읽은 파일은 identity·mode·size·mtime·ctime을 끝에서 다시 확인한다. 검증은 Swift 협력 실행기 밖의 Dispatch 작업에서 수행하고 취소는 검증/읽기 체크포인트에서 처리한다. Security/파일 시스템 호출의 즉시 중단은 보장하지 않는다.

선택한 앱의 CodeDirectory hash·identifier/Team/ad-hoc 상태와 manifest hash를 provider에 고정한다. entries/extract마다 bundle을 다시 검증해 이 identity까지 일치해야 worker를 만든다. 파일을 정상적으로 재서명하고 manifest hash도 갱신한 새 bundle은 새 factory에서 선택할 수 있지만 기존 provider가 조용히 바뀌지는 않는다. 검증과 exec/dlopen 사이를 단일 원자적 동작으로 만든 것은 아니며 악의적 동시 교체 전체를 차단했다고 표현하지 않는다.

## 검증

ARM 실제 서명 bundle과 공식 reference를 사용한 SDK 게이트 19개가 모두 통과했다. 기존 통신/추출 검사 9개에 manifest/경로/FIFO·취소·서명 requirement 문법·호스트 identity와 실제 bundle 검사 10개를 추가했다.

실제 bundle을 독립 시험 폴더에 복사해 factory로 선택하고 Unicode 암호·한글/emoji/LF 이름과 512KiB 파일을 복원했다. 선택 후 resource 변조, 재서명한 resource hash 불일치, hash 목록까지 갱신한 source pin 불일치, 외부 파일 추가를 거부했다. stable로 바꿔 ad-hoc 재서명한 앱도 거부했다. helper와 부모 signature가 모두 유효하지만 helper identifier만 다른 fixture를 만들어 역할 일치 검사를 확인했다. 다른 유효한 revision으로 전체를 재서명한 경우 새 factory는 성공하고 이전 provider는 changedBundle로 실패했다.

기본 CI selector는 앱 fixture가 필요한 5개를 제외한 14개를 실행하고, package selector는 19개 전체를 실행한다. 두 selector의 실제 성공과 건너뜀 없음을 확인했다. 외부 reference/worker fixture를 함께 요구하는 기존 4개 테스트의 조건도 각각의 존재 조건을 AND로 연결했다. 다른 볼륨 시험에서 쓰는 공용 OR helper는 바꾸지 않았다. [검증·소스/도구 해시](archive-bundle-resolver-349-verification.json).

Core 전체는 415개 중 성공 396개·환경 건너뜀 19개로 통과했다. Debug 앱/테스트와 최종 Release 빌드도 통과했다. 호스트 test runner 서명 분류 단언을 갱신한 뒤에는 해당 변경을 포함한 전체 SDK 19개와 기본 14개 selector를 다시 검증했다. Python/shell 구문·parity 구조·diff 검사도 통과했다. 앱 UI·기존 ZIP 경로는 유지해 기존 전체 AppKit UI를 반복하지 않았다. 새 DMG를 만들지 않고 348의 실제 서명 bundle을 resolver fixture로 사용했다.

직전 [58b6d82 CI](https://github.com/taro6222/files-for-mac/actions/runs/45780983666)의 macOS 15 ARM·Intel Swift 게이트에서 EOF 회귀를 포함한 9개가 각각 성공했고 두 actual artifact를 확인했다. 종료 상태는 ARM 전체 성공·Intel 전체 AppKit 단계 실패다. 이 결과를 새 resolver 19개의 두 CPU 수용으로 집계하지 않는다.

실제 Developer ID 자격으로 서명한 코드의 runtime 확인·공증은 아직 수행하지 않았다. 이 단계의 requirement 파싱과 ad-hoc stable 거부를 그 수용으로 대신하지 않는다. 인증서·공증 프로필은 사용자 준비 중이다. ArchiveWindow와 일괄 추출은 현재 기존 provider를 유지하며 7z password capability도 미지원 상태다. 다음은 여기/스마트 배치의 안전한 게시와 UI/암호 흐름 연결이다. 메타데이터 복원·생성/세부 옵션/분할·decoder 메모리/권한 격리·지원 환경/최신 장시간·원본 UI/실제 입력/VoiceOver는 계속 남아 있다.
