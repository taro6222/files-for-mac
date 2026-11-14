# M7 Increment 172 — macOS CI

GitHub Actions에서 main 푸시와 main 대상 PR, 수동 실행에 macOS 15의 arm64·x86_64 잡을 실행하도록 구성했다. 두 잡 모두 실제 아키텍처를 대조하고 Xcode 26.3에서 원본 인벤토리, Swift 테스트, APFS·대소문자 구분 APFS·exFAT·FAT32·HFS+ 마운트 시험을 실행한다. [GitHub 러너 목록](https://github.com/actions/runner-images/blob/main/README.md)

볼륨 스크립트는 선택한 Xcode의 Swift Testing을 사용한다. 별도 Command Line Tools 환경에서 해당 매크로 라이브러리가 설치된 경우 그 경로를 전달한다.

이 워크플로의 범위는 빌드·Swift 동작·로컬 임시 볼륨이다. macOS 14 실행, 서명·공증된 DMG, AppKit 수동 검증과 VoiceOver, SMB·외부 서비스는 출시 검증 현황에서 추적한다.
