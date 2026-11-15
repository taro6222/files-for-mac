# M7 Increment 208 — 상하 분할 화면 검증 경로

상하 분할에서 위 패널에 공통 폴더의 다섯 항목, 아래 패널에 `Alpha`의 `column-note.txt`가 보이는지 검증한다. Windows 캡처는 좌우 분할을 닫고 공통 폴더로 돌아간 뒤 원본의 상하 분할 명령을 실행한다. 접근성 트리에서 양쪽 목록이 서로 겹치지 않고 실제로 상하에 정렬됐는지도 확인한다. 좌우 분할 캡처에도 별도의 수평 배치 검사를 적용한다. [Windows 상하 분할 명령](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Navigation/SplitPaneHorizontallyAction.cs)

Windows의 실제 좌우 분할 접근성 트리와 모의 상하 배치로 판정 로직을 검증했다. 겹친 패널과 배치 방향이 다른 트리를 거부했다. Windows 원본 상하 분할 캡처는 GitHub Actions에서 확인한다.

Apple Silicon macOS 27.2에서 앱 빌드와 영어·밝은 테마 AppKit 검사 293개를 통과했다. 좌우를 상하로 바꿔도 두 폴더와 아래 패널의 활성 상태를 유지했고 첫 파일 행은 헤더 아래에 나타났다. [macOS 상하 분할 화면](ui-06-macos-reference-stacked.png)
