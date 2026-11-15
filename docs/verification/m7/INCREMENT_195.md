# M7 Increment 195 — 공통 시험 폴더의 그리드와 컬럼 보기

공통 시험 폴더의 최상위 다섯 항목을 유지하고 `Alpha` 아래에 `column-note.txt`를 추가했다. 두 앱에서 그리드의 다섯 항목과 컬럼 보기에서 `Alpha`를 선택했을 때 오른쪽 열에 나타나는 파일을 대조하는 데 사용한다.

Windows 캡처는 고정 원본의 보기 단축키로 전환한다. 같은 경로와 다섯 항목, 그리드 접근성 요소가 확인되면 UI-04를 저장한다. 컬럼 보기에서는 `Alpha`를 선택하고 접근성 트리의 인접한 두 컬럼에 각각 `Alpha`와 하위 파일이 확인되면 UI-05를 저장한다. 각 캡처의 SHA-256과 접근성 트리를 남긴다. [원본 보기 단축키](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Display/LayoutAction.cs)

Apple Silicon macOS 27.2에서 앱을 빌드하고 영어·밝은 테마 AppKit 검사 279개를 통과했다. [그리드 캡처](ui-04-macos-reference-grid.png) · [컬럼 캡처](ui-05-macos-reference-columns.png)

Windows의 이전 홈·상세 접근성 트리와 모의 그리드·컬럼 응답으로 캡처 작업을 재생했다. Windows 실기 캡처와 시각 비교는 GitHub Actions 결과가 나온 뒤 검증한다.
