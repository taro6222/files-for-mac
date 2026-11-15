# M7 Increment 203 — 공통 폴더를 사용한 분할 보기 검증

공통 시험 폴더를 두 패널에 표시한 뒤 오른쪽 패널에서만 `Alpha`를 연다. 왼쪽에 그대로 남은 다섯 항목과 오른쪽의 `column-note.txt`를 확인한다. Windows는 고정 원본의 분할 단축키와 기본 좌우 배치를 사용한다. 접근성 트리에서 보이는 두 파일 목록과 각각의 항목을 확인한 뒤 캡처를 저장한다. [Windows 분할 명령](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Show/ToggleDualPaneAction.cs)

Windows에서 앞서 수집한 상세 보기 트리와 모의 두 번째 패널로 캡처 판정을 검증했다. 오른쪽 패널이 숨겨진 경우와 하위 폴더를 열기 전에는 최종 캡처를 저장하지 않는다. Windows 배포 패키지의 실행 캡처는 GitHub Actions에서 검증한다.

macOS 분할 화면을 캡처하는 과정에서 새 위치의 스크롤을 0으로 설정하면 오른쪽 첫 파일 행이 상세 열 헤더에 가려지는 문제를 재현했다. 상세 보기의 두 패널에서 새 위치의 헤더 높이와 AppKit이 허용하는 스크롤 범위를 적용한다. 이력에 저장된 다른 스크롤 위치도 현재 범위 안에서 복원한다. [AppKit clip view 인셋](https://developer.apple.com/documentation/appkit/nsclipview/contentinsets)

Apple Silicon macOS 27.2에서 앱을 빌드하고 영어·밝은 테마 AppKit 검사 286개를 통과했다. 실제 분할 영역의 서로 다른 폴더, 오른쪽 패널의 활성 상태, 상세 보기 첫 행이 헤더 아래에 배치된 것을 확인했다. [macOS 분할 화면](ui-06-macos-reference-dual-pane.png)

한국어·영어와 밝은·어두운 테마 네 조합에서 분할 패널을 포함한 AppKit 파일 작업 검사도 각 71개를 통과했다.
