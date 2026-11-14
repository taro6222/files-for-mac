# M7 Increment 17 — 유니버설 앱 배포 대상 검사

`build-app.sh --universal`은 앱 서명 후 `verify-universal-app.sh`를 실행한다. 검증기는 Info.plist의 실행 파일명과 최소 버전, arm64·x86_64 슬라이스의 Mach-O 플랫폼과 최소 macOS 버전, 두 슬라이스의 코드 서명을 확인한다. 두 슬라이스 모두 macOS 14.0을 대상으로 해야 DMG 제작으로 넘어간다.

macOS 27.2 (26B123)에서 프리뷰 DMG를 다시 제작해 SHA-256을 확인했다. 읽기 전용으로 마운트한 이미지의 앱에서 같은 검증을 통과했다. Intel 슬라이스가 빠진 번들, macOS 15.0용으로 링크한 실행 파일, 최소 버전이 15.0인 Info.plist는 각각 거부했다.

이 Mac에서 x86_64 프로세스 실행은 지원되지 않는다. Intel 및 macOS 14에서의 실제 기동과 회귀는 계속 출시 조건으로 둔다.
