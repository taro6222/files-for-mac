# M7 Increment 04 — 유니버설 설치 이미지

- DMG에 Apple Silicon용 arm64와 Intel용 x86_64 Release 바이너리를 합쳐 넣는다. 아키텍처별 SwiftPM 빌드 디렉터리를 사용하며 두 슬라이스를 검사한 뒤 앱과 이미지를 만든다.
- 2026-11-14 macOS 27.2 (26B123)에서 `b96bd1fe9892dc0aa6a2f5008a6c9a57d146d76e`의 앱 소스를 사용해 0.1.0 유니버설 프리뷰 DMG를 생성했다.
- DMG 읽기 전용 마운트, 두 슬라이스의 ad-hoc 코드 서명, Applications 링크, Apple Silicon 기동을 확인했다. Intel 슬라이스는 교차 컴파일과 서명을 검증했다. 이 호스트에서는 x86_64 프로세스 실행을 지원하지 않아 Intel 실기기 실행을 M7 검증 항목에 유지한다.
- DMG SHA-256은 `c00db780faa886250fec571950da3da30d04e00d41d104eb6c50f81f423741d1`이다.

[남은 환경별 출시 검증](RELEASE_GATES.md)
