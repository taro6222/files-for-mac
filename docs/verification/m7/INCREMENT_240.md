# M7 Increment 240 — 동일 파일의 macOS 속성·해시 화면

Apple Silicon macOS 27.2의 영어·밝은 테마에서 [공통 시험 파일](../../../scripts/create-ui-reference-fixture.py) `preview.txt`의 속성 창을 열었다. [일반 화면](ui-09-macos-reference-general.png)에서 파일명, 위치, 논리 크기 24바이트, 수정 시각, 소유자와 권한을 확인했다. 같은 파일을 연 [Windows 일반 화면](ui-09-windows-reference-general.png)은 Windows의 위치, 디스크 크기와 날짜를 표시한다. 할당 크기와 생성 시각은 두 실행 환경에서 다르게 나타났다.

[macOS 해시 영역](ui-09-macos-reference-hashes.png)의 SHA-256 전체 값은 [Windows 실행 기록](INCREMENT_238.md)의 값과 일치했다. 두 화면은 입력한 해시와 다른 파일을 비교하는 기능을 제공한다. Windows는 여러 알고리즘의 결과를 한 표에 표시하고 macOS는 팝업에서 알고리즘을 선택해 계산한다.

AppKit 검사 307개를 통과했고 같은 파일의 이름·논리 크기·SHA-256을 확인했다. 속성 창의 이름 편집과 Windows 보안·서명 상태 대조는 열린 항목이다.
