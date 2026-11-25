# M7 Increment 291 — 제한된 실행기 검사의 테스트 호스트 분리

[소스 5225bfe의 원격 실행](https://github.com/taro6222/files-for-mac/actions/runs/45625407162)에서 Apple Silicon의 빌드와 기본 264개 시험은 통과했다. 이어지는 제한 실행기 단계는 시험 시작 출력 없이 2분 제한에 도달해 전체 AppKit 검사에 도달하지 못했다. Git 구현의 회귀 검사 실패나 UI 시간 초과 해결을 이 결과로 판정하지 않는다.

`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`을 SwiftPM 명령 실행기 전체에 적용하던 구성을 실제 Swift Testing 호스트에만 적용하도록 분리했다. [SwiftPM 6.2의 테스트 호스트 호출](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/Commands/SwiftTestCommand.swift)과 [호스트 진입점](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/swiftpm-testing-helper/Entrypoint.swift)을 확인했다. 도구 체인·빌드 경로 확인은 제한 환경 밖에서 실행하고 `swiftpm-testing-helper`가 실제 테스트 번들의 바이너리를 직접 불러온다. Command Line Tools와 Xcode의 Testing 프레임워크·런타임 경로를 각각 반영한다.

스크립트는 선택한 세 시험의 실제 통과 출력을 모두 확인한다. 실패·시간 초과는 실패 상태로 기록하며 시간 초과 시 테스트 호스트의 스택을 보존한다. CI에서 로그와 JSON을 별도 아티팩트로 남긴다. 검사 수나 제한된 실행기 조건은 줄이지 않았다.

macOS 27.2.1(26B131), Swift 6.4.2에서 세 시험이 모두 통과했다. [호스트 실행 결과](git-scheduling-host-macos27.2.1.json). 워크플로 YAML 구문 검사도 통과했다. macOS 15·Xcode 26.3에서의 후속 실행과 전체 AppKit 결과는 계속 확인한다.
