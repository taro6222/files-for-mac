# M7 Increment 139 — 최신 프리뷰 소스 AppKit 회귀

Apple Silicon macOS 27.2 (26B123)에서 프리뷰 커밋 `a2c8467`과 `Sources` 및 `Package.swift`가 동일한 디버그 빌드로 AppKit 회귀를 실행했다. 각 조합은 독립 환경에서 한국어 또는 영어와 밝은 또는 어두운 테마를 사용했다.

검사에는 원격·Git 패널의 접근성 속성, 검색 결과의 키보드 탐색, 탭·분할 보기와 파일 작업 명령이 포함된다. 이 회귀는 macOS 앱 내부를 실행한다. Windows 실행 화면 대조와 VoiceOver 음성 출력은 별도 검증 항목이다.

네 조합에서 각각 258개가 통과했다. [검사 및 측정 원본](appkit-regression-a2c8467.json)
