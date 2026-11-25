# M7 Increment 284 — Xcode 프로젝트의 현재 소스와 코어 연결

README의 Xcode 진입점을 점검한 결과 프로젝트에 Swift 소스 15개만 등록돼 있었고 현재 소스 85개 중 70개가 빠져 있었다. 전체 코어를 앱 타깃에 합치면 `FilesCore` 모듈을 가져오는 앱 파일이 컴파일되지 않아 로컬 패키지 제품을 연결하도록 생성기를 변경했다. [Apple 로컬 패키지 안내](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages)

앱 타깃은 현재 `Sources/FilesMac`의 44개 파일을 컴파일한다. 코어 41개와 libarchive 시스템 모듈은 기존 `Package.swift`의 `FilesCore` 제품으로 연결한다. 생성한 프리뷰 앱의 채널도 번들에 기록한다. 프로젝트 생성 결과의 반복 일치, 등록한 전체 앱 파일과 실제 파일의 일치, 코어 제품 참조 및 plist 구문을 대조했다.

Command Line Tools의 Swift 6으로 `FilesCore` 모듈을 생성하고 해당 모듈을 가져오는 전체 앱 소스를 타입 검사했다. 로컬 `xcodebuild`는 Xcode 라이선스 동의 단계에서 중단돼 네이티브 앱 링크와 실행은 검증하지 못했다. 수동 워크플로의 `verify_xcode`로 macOS 15 Apple Silicon·Intel 러너에서 프로젝트 생성 일치, 네이티브 빌드와 생성 앱 채널을 확인한다. 실제 CI 결과는 후속 실행에서 판정한다.
