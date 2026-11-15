# M7 Increment 251 — 중첩 앱의 속성 창 서명 표시

Apple Silicon macOS 27.2의 영어·밝은 테마에서 [정상 중첩 앱과 보조 실행 파일의 서명이 제거된 앱](INCREMENT_249.md)을 속성 창에 열고 코드 서명 확인을 실행했다. [정상 앱 화면](ui-09-macos-reference-nested-signed.png)은 유효 상태, 바깥 앱 식별자, 앱 번들의 Mach-O 형식을 표시했다.

[손상된 앱 화면](ui-09-macos-reference-nested-invalid.png)은 유효하지 않음 상태와 같은 바깥 앱 식별자를 표시했다. 진단에서 실패한 하위 구성 요소 `Helper.app`의 전체 경로와 아키텍처를 확인했다.

전체 AppKit 검사 312개가 통과했다. 두 앱 상태와 함께 단일 Mach-O의 ad-hoc 서명과 미서명 텍스트를 다시 확인했다. 배포 인증서로 서명한 앱의 확인은 남아 있다.
