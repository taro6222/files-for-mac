# M7 Increment 213 — 공통 폴더 검색 화면 검증 경로

공통 폴더에서 `column-note`를 검색한다. 기대 결과는 하위 폴더 `Alpha`에 있는 `column-note.txt` 한 개다. Windows 캡처는 `Ctrl+F`로 Omnibar를 열고 입력값을 확인한 뒤 제출한다. 검색 제목과 정확한 결과 목록이 표시되면 화면을 저장한다. [Windows 검색 명령](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Global/SearchAction.cs)

실제 Windows 탐색 트리는 검색 결과로 승인하지 않았고 모의 검색 트리에서는 결과가 하나인 경우에만 승인했다. Windows 원본 캡처는 GitHub Actions에서 검증한다.

Apple Silicon macOS 27.2의 앱 빌드와 영어·밝은 테마 AppKit 검사 294개를 통과했다. 검색 창에서 `Alpha` 아래의 `column-note.txt` 한 개가 정확한 전체 경로로 반환됐다. [macOS 검색 화면](ui-07-macos-reference-search.png)
