# M7 Increment 218 — 공통 폴더의 macOS 정보 패널

Windows와 macOS에서 사용하는 공통 폴더에서 `preview.txt`의 상세 정보와 Quick Look 연결을 확인한다. 미리보기 탭을 유지하며 `Alpha` 폴더를 선택하면 이전 Quick Look 항목이 해제되고 선택한 폴더의 이름과 미리보기 불가 안내가 표시되는지 검사한다.

Apple Silicon macOS 27.2의 영어 밝은 테마에서 앱을 빌드하고 새 검사 3개를 포함한 AppKit 검사 298개를 통과했다. 상세 화면에는 `preview.txt`의 경로·종류·24바이트 크기·수정일·소유자·태그가 표시된다. Quick Look 검사에서는 선택 파일 URL 전달을 확인했다. Windows 실행 화면과 Quick Look의 본문 렌더링은 추가 확인이 필요하다. [파일 상세](ui-08-macos-reference-details.png) · [폴더 미리보기 불가](ui-08-macos-reference-preview-unavailable.png)
