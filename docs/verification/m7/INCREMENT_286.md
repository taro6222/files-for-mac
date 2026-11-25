# M7 Increment 286 — 최신 호스트의 전체 AppKit 재현 대조

Intel CI의 시간 초과를 대조하기 위해 현재 앱의 전체 AppKit 검사를 Apple Silicon macOS 27.2.1(26B131)에서 실행했다. 한국어·영어와 밝은·어두운 테마 네 조합이 각각 283개를 통과했고 네 보고서의 검사 키와 요청한 언어·테마를 대조했다. 이 환경에서는 180초 제한 안에 모든 조합이 끝났다. [전체 보고서](full-appkit-207d6bf-macos27.2.1.json)

검증 바이너리 SHA-256은 `ec8e58a00cd75a3a30d2d8d7e0858ca0d7e1551abb8d409d0fd20b6d2a6797b6`다. 이 실행에 사용한 앱 소스 `207d6bf8a742c59f988fa1944fd801c18b929642`와 실행 시점 HEAD의 `Sources` 차이가 없음을 확인했다. 두 업데이트 창 검사가 포함된 전체 UI 회귀이며 실제 VoiceOver 출력 검증은 별도로 남아 있다.

같은 Mac에서 8시간 전체 부하 시험도 실행 중이었다. 여기서는 각 UI 검사의 결과를 확인했으며 성능 기준의 독립 측정으로 판정하지 않는다. [macOS 15 재시험](https://github.com/taro6222/files-for-mac/actions/runs/45617289965)의 결과와 필요 시 시간 초과 스택을 대조해 Intel 실패 원인을 확인한다.
