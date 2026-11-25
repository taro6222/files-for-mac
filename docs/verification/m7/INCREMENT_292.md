# M7 Increment 292 — 파일 약속 송신 구현과 계약 검사

상태: F17 진행 중. 송신 코드와 제공자 계약 검사를 추가했으며 실제 마우스 드래그·외부 앱 수신 수용 검증은 미완료다. 파일 약속 수신 동선도 후속 개발 항목으로 남아 있다.

상세 목록·그리드·목록·컬럼 및 보조 패널의 드래그 writer에 `NSFilePromiseProvider` 기반 제공자를 연결했다. 기존 파일 URL도 제공한다. 목록에서 읽은 identity를 보관하므로 드래그 시작 시 추가 파일 시스템 조회나 복사를 하지 않는다. identity를 읽지 못한 항목은 기존 파일 URL 전송을 유지한다. 요청된 파일명과 폴더·패키지의 UTI를 제공하고 공유 백그라운드 큐의 동시 전송을 두 개로 제한한다.

수신 앱이 전달한 정확한 파일명으로 기존 복사 엔진을 실행한다. 원본 identity를 전송 전·후·게시 직전에 확인하고 대상 충돌은 오류로 돌려보낸다. 파일·폴더·심볼릭 링크와 메타데이터를 기존 검증·비덮어쓰기 게시 경로로 처리한다. 외부 수신 앱의 작업이 자체 앱의 실행 취소 기록을 바꾸지 않도록 분리했다. 복구 정보가 필요 없는 저널은 완료 콜백 전에 정리한다.

[검증 원본·소스 및 실행 파일 해시](file-promise-contract-macos27.2.1.json): 앱·테스트 빌드, 복사·템플릿·신규 내보내기의 코어 15개, AppKit 제공자 계약 18개, 대응표 구조 감사와 셸·워크플로 구문 검사가 통과했다. 계약 검사는 실제 제공자의 이름·백그라운드 큐와 쓰기 콜백을 사용해 수신자 지정 이름, 권한, 충돌 오류, 기존 대상 보존, 교체된 원본 거부, 폴더와 링크 복사를 확인한다. AppKit receiver로 읽을 수 있는 타입과 기존 URL 표현도 확인한다. 실제 드래그 완료를 이 검사로 판정하지 않는다.

`scripts/verify-file-promises.sh --binary <debug FilesMac>`는 고유 번들 ID의 ad-hoc 시험 앱을 Launch Services로 열고 별도 도구가 실제 마우스 이벤트를 보낸다. 자기 시험 앱이 활성 상태일 때만 입력하며 두 QA 영역 사이에서 실제 드래그 세션을 만들고 `NSFilePromiseReceiver` 완료를 기다린다. 현재 Mac에서 `CGSSessionScreenIsLocked=1`, 전면 앱 `com.apple.loginwindow`를 확인해 실제 드래그는 보류했다. 잠금 해제가 필요하다고 사용자에게 알렸다. `--contract` 검사는 이 수용 검증과 구분하며 잠금 상태에서도 실행할 수 있다. 시험 코드는 DEBUG에만 포함된다. [Apple의 파일 약속 드래그 예제](https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises)

CI에 두 CPU의 제공자 계약 검사와 보고서 보존을 추가했다. 이전 소스 `5225bfe`의 Intel 실행은 빌드 20분 제한에 도달했다. 빌드의 디버그 정보 설정을 SwiftPM의 `-debug-info-format none`으로 명시했다. 로컬에서 기존 `-Xswiftc -gnone` 설정에도 실제 frontend에 `-g`가 적용된 것을 확인했으며 명시적 설정의 빌드를 통과했다. Intel의 제한 시간은 유지하며 후속 원격 결과로 판정한다. [SwiftPM 6.2의 해당 옵션](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/CoreCommands/Options.swift)

[제한 실행기 호스트 분리 소스 3a65d40의 후속 실행](https://github.com/taro6222/files-for-mac/actions/runs/45629049035)에서 두 CPU의 해당 세 시험이 모두 통과했다. [CI 원본 결과](git-scheduling-3a65d40-ci.json). Apple Silicon은 이후 Spotlight 준비 단계에서 실패했고 Intel의 전체 AppKit 검사는 진행 중이다. 전체 결과·설치 프리뷰·8시간 시험·서명과 공증은 계속 확인한다.
