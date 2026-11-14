# M7 Increment 182 — 설치 이미지와 장시간 시험 바이너리의 빌드 대조

`python3 scripts/verify-soak-build.py <장시간 시험 FilesMac> <마운트된 Files macOS.app>`로 현재 CPU 슬라이스의 Mach-O 플랫폼, 최소 OS, SDK 기록을 대조한다. `--architecture`로 대상 슬라이스를 선택할 수 있다. JSON에 두 실행 파일 전체의 SHA-256을 남긴다. 플랫폼·최소 OS·SDK 차이는 종료 코드 1, 읽을 수 없는 바이너리나 존재하지 않는 슬라이스는 2다.

프로젝트의 프리뷰 DMG 체크섬을 대조한 뒤 읽기 전용으로 마운트했다. 그 안의 arm64 슬라이스와 진행 중인 Swift Build 장시간 QA 앱은 최소 OS와 SDK 값이 모두 14.0이다. 관련 앱·패키지 소스도 `36057ca`와 `9c56f83` 사이에서 일치했다. [일치 결과](soak-build-metadata-arm64.json)

별도 SwiftPM 네이티브 엔진의 실제 QA 바이너리를 입력하면 SDK 27.2 차이로 실패하고, arm64 전용 QA 바이너리에 x86_64를 지정하면 읽기 단계에서 실패함을 확인했다. SDK 대조는 [스크롤 객체의 SDK별 차이](INCREMENT_181.md)를 확인한 뒤 추가했다. 8시간 시험 종료, 동일 앱 소스 및 설치된 바이너리의 실행 검증은 각 증거로 별도 판정한다.
