# 366단계 — 최신 유니버설 프리뷰와 실제 컴파일러 관찰

기록일 2026-11-27. 제품 소스 0420df1889b002d4ea9c8191f236f3ef2ad50536. 프리뷰 산출물 생성과 추출한 payload 검증은 통과했으나 마운트 설치 수용·컴파일 시간 문제와 M7 전체는 진행 중이다.

## 프리뷰 산출물

로컬 파일: `build/preview-366/Files-macOS-preview.dmg` (10,443,332바이트). 같은 폴더의 `.sha256`으로 확인한다.

SHA-256: `b66c2d82a678d9a8df36f2ea45297b33e95a7dc40428d6afa584ab1f9a70a9ea`.

`scripts/build-dmg.sh --preview`로 Apple Silicon Release 55.93초·Intel Release 57.01초 빌드 후 앱·helper·라이브러리를 각각 합쳤다. 두 CPU 모두 최소 macOS 14.0 메타데이터, 서명·manifest·고지·대응 소스·정확한 파일 집합을 staging에서 검증했다. UDZO 이미지 생성과 hdiutil 체크섬 검사가 통과했다. ad-hoc 개발 프리뷰이며 정식 서명·공증이나 Intel 실행 수용을 의미하지 않는다.

## 읽기 전용 마운트와 별도 payload 검증

Finder 창이나 앱을 열지 않고 읽기 전용 마운트했다. 내용물 검사 60초 제한을 넘겼다. 이후 단계 추적·소유 프로세스 진단·45초 제한을 추가한 별도 관찰에서 bash가 루트 폴더 glob의 `__opendir2 → open$NOCANCEL → __open_nocancel`에서 대기함을 확인했다. 제품 코드나 SDK 실행에 도달하기 전이다. 원인을 확정하지 않는다.

두 이미지 모두 강제 해제 없이 정상 detach했고 최종 hdiutil 조회에서 해당 이미지가 남지 않았음을 확인했다. 소유한 조회 프로세스도 종료했다. 시간 초과를 마운트 수용 성공으로 바꾸지 않는다.

고정 공식 7zz는 같은 DMG의 APFS 내용을 읽고 추출했다. 추출 과정에서 별도 파일로 표현된 `com.apple.provenance` alternate stream 22개는 해시를 기록하고 data fork 재구성에서 제외했다. 7zz가 안전한 로컬 경로로 바꾼 Applications symlink는 원본 APFS 목록에서 `/Applications`임을 확인해 복원했다. 이미지 자체는 변경하지 않았다.

이렇게 추출한 실제 앱에서 기존 DMG 내용물 검사와 모든 CPU의 엄격한 서명·manifest 검증이 통과했다. 실제 ARM 실행에서는 Swift 클라이언트 57개(17.537초), 격리 helper 50개, 별도 진단 SDK 142개, 권한 probe 15개가 통과했다. 이는 추출한 payload 검증이며 마운트된 설치·Gatekeeper·전체 GUI 수용의 대체 증거가 아니다.

## 컴파일 시간 조사

이전 362 소스 Intel 작업은 앱/테스트 빌드 단계에서 20분 제한으로 종료됐다. 현재 유지 중인 364 소스 실행의 ARM 진단은 별도 그룹의 실제 swift-frontend 자식까지 포함한다. 2분 관찰에서는 LLVM CoroSplit, 6분 관찰에서는 LazyCallGraph의 분할 coroutine 연결, 10분 관찰에서는 CoroCleanup/SimplifyCFG 경로가 수집됐다. CPU는 활성이고 관찰 RSS는 최대 약 3.33GiB였다. 빌드는 638.620초에 정상 완료했다.

따라서 빌드 관리자의 CPU 0%만 보고 교착/유휴라고 설명할 근거는 없다. 이번 자료는 LLVM 비동기 함수 변환 비용을 좁히는 근거다. BrowserWindow의 큰 UI 검증 함수는 2,500줄 이상·await 약 200개지만 특정 함수가 병목임을 아직 증명하지는 못했다. 원격 Intel은 마지막 조회에서 같은 빌드가 진행 중이었다. 제한 시간 확대·실행 재시작이나 근거 없는 컴파일러 옵션 변경은 하지 않았다.

[산출물·검증·실패·컴파일러 진단 해시](preview-and-compiler-366-verification.json)를 보존한다. 제품/검증 코드 변화가 없는 기록 커밋은 `[skip ci]`를 사용해 진행 중인 364 실행과 대기 중인 365 제품 소스 검증을 그대로 유지한다. 필요한 양 CPU 수용을 생략하는 뜻이 아니다.

## 남은 항목

마운트 경로 접근과 설치 수용, 컴파일러 비용의 정확한 소스 분리·필요한 수정, 최신 양 CPU/지원 환경, 원본 전체 UI·물리 입력·VoiceOver, 나머지 metadata·자원 경계·외부 서비스와 장시간 수용, Developer ID·공증·정식 설치/업데이트는 미완료다. 로컬 GUI·장시간 시험은 재실행하지 않았다. 인증서·notarytool 프로필은 사용자 준비 중이다.
