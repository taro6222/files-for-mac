# M7 Increment 16 — 정식 DMG 검증과 배치

정식 DMG 제작은 `notarytool`의 구조화된 응답에서 제출 ID와 상태를 읽는다. `Accepted`일 때 티켓을 첨부한 뒤 티켓·이미지 서명·Gatekeeper 평가를 진행한다. 최종 이미지의 무결성 검사를 마치고 SHA-256 파일을 생성한 뒤 빌드 경로에 배치한다. 유니버설 앱의 두 아키텍처 서명은 이미지에 담기 전에 확인한다. [Apple 공증 절차](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

macOS 27.2 (26B123)에서 스크립트 구문 검사를 통과했다. 실제 프리뷰 DMG를 다시 빌드해 무결성과 SHA-256을 확인했다. 정식 경로는 임시 위치에서 실제 DMG 제작 도구를 사용하고 서명·공증·Gatekeeper를 모의했다. 공증 명령 실패·공증 거절·Gatekeeper 거부 후 기존 DMG와 체크섬 파일이 보존됐고, 모의 승인 경로의 새 DMG와 체크섬은 일치했다. 이 Mac에서 존재하지 않는 Developer ID 이름으로 실행하면 빌드 전에 종료하는 것도 확인했다.

실제 Developer ID 서명, Apple 공증 승인, 티켓 첨부 및 깨끗한 Mac의 다운로드 실행 검증은 자격 증명 준비 후 진행한다.

정식 빌드는 티켓을 첨부하고 SHA-256 파일을 만든 다음, [다운로드할 때 사용하는 검증 스크립트](INCREMENT_21.md)를 스테이징 DMG에 실행한다. 이 검증을 통과해야 기존 산출물을 교체한다. 실제 DMG 제작 도구와 모의 공증·검증 명령으로 공증 요청 실패, 공증 거절, 승인 후 최종 검증 실패, 최종 검증 통과를 확인했다. 실패 세 경우 모두 이전 DMG와 체크섬이 보존됐으며, 통과한 새 DMG의 SHA-256이 일치했다.
