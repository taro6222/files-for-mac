# M7 Increment 178 — CI에서 설치한 개발 프리뷰 실행

macOS 15의 Apple Silicon 및 Intel 푸시·수동 CI가 유니버설 개발 DMG를 만들고 임시 경로에서 읽기 전용 마운트, 복사, 서명 검증을 실행한다. 별도 설정 도메인을 사용하는 앱을 Launch Services로 열고 지정된 폴더의 창과 실행 프로세스의 실제 CPU 아키텍처를 20회 확인한다. CI 창 목록 검사는 접근성 메뉴 조작 권한을 요구하지 않는다.

Apple Silicon macOS 27.2에서 기존 검증 이미지로 새 실행 경로를 확인했다. 20회 모두 지정 폴더의 창과 arm64 프로세스를 확인했다. YAML 파싱과 설치 모드에서의 잘못된 `--launch-services` 사용 거부도 검사했다.

이 검증은 개발 이미지의 설치·실행 경로다. 정식 서명·공증과 Gatekeeper, 최소 macOS 14, VoiceOver와 전체 수동 동선은 출시 검증 현황에서 추적한다.
