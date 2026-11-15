# M7 Increment 220 — Quick Look 텍스트 본문 렌더링 검증

공통 폴더의 `preview.txt`를 정보 패널에 표시하고 화면을 캡처한다. 디버그 UI 시험에 `FILES_UI_QA_PREVIEW_TEXT=1`을 지정하면 패널의 AppKit 캡처를 Vision으로 읽어 파일 본문을 찾는다. Quick Look이 비동기로 그리는 동안 최대 5초 동안 캡처를 갱신한다.

Apple Silicon macOS 27.2의 영어 밝은 테마에서 `Files reference preview`가 화면에 표시되는 것을 확인했다. AppKit 검사 299개를 모두 통과했다. 다른 확장에서의 Quick Look 렌더링과 Windows 화면 대조는 추가로 검증한다. [macOS 텍스트 미리보기](ui-08-macos-reference-preview.png)
