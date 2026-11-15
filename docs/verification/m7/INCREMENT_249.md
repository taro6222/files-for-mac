# M7 Increment 249 — 중첩 코드의 서명 무효 상태

Apple Silicon macOS 27.2에서 Mach-O 사본으로 바깥 앱과 중첩 보조 앱을 만들고 안쪽부터 ad-hoc 서명했다. 정상 복사본은 `codesign --verify --deep --strict`를 통과했다. 별도 사본에서 보조 실행 파일의 서명만 제거하자 바깥 앱의 서명 정보는 남았으며, 재귀 검증은 보조 앱을 서명 문제의 하위 구성 요소로 보고했다. [Apple 중첩 코드 검증](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

FilesCore는 선택한 대상의 직접 서명 조회에서 미서명이 확인된 경우에 해당 상태를 표시한다. 바깥 앱의 서명이 있고 내부 코드 때문에 재귀 검증이 실패하면 유효하지 않음으로 반환하고 진단과 바깥 앱 식별자를 유지한다.

Swift Testing 3개가 통과했다. 정상 중첩 앱, 내부 서명이 제거된 앱, 미서명 텍스트의 실제 결과와 진단, 대량 출력을 처리하는 경로와 메타데이터 파싱을 확인했다. 중첩 번들의 AppKit 표시와 정식 인증서 검증은 남아 있다.
