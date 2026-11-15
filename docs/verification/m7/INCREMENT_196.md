# M7 Increment 196 — 홈의 Finder 파일 태그 위젯

홈에서 파일 태그 위젯을 켜면 Spotlight가 색인한 로컬 항목을 Finder 태그별로 표시한다. 같은 항목이 여러 태그에 속하면 해당 그룹에 각각 나타난다. 파일·패키지는 일반 파일 열기로 전달하고 폴더는 탐색 창에서 연다. 일반 설정과 탐색 옵션의 홈 메뉴에서 표시를 변경할 수 있다. 표시와 펼침 상태는 따로 저장한다. 원본의 기본값에 맞춰 처음에는 위젯을 숨기고 켜면 펼친다.

macOS는 Spotlight에서 최근 수정 순으로 최대 1,000개를 읽고 태그 20개, 태그별 항목 4개까지 표시한다. Windows의 위젯은 원본 Files의 자체 태그 저장소에서 항목을 가져온다. 다시 홈에 들어가거나 새로 고치면 색인을 다시 조회한다. [Windows 위젯 구현](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/ViewModels/UserControls/Widgets/FileTagsWidgetViewModel.cs) · [Apple Spotlight 조회 API](https://developer.apple.com/documentation/foundation/nsmetadataquery)

Apple Silicon macOS 27.2에서 실제 Spotlight 조회가 이미 색인된 항목 한 개를 두 태그에 분류했다. 테스트 호스트의 색인은 읽기 전용이라 새 파일에 추가한 태그가 색인에 반영되는 동선은 남아 있다. AppKit의 재현 가능한 시험 데이터로 그룹 표시, 파일 열기와 홈 표시 설정의 독립성을 확인했다. Swift Testing에서 위젯 상태의 재실행·내보내기·기존 설정 가져오기를 검사했다.

영어·밝은 테마 AppKit 검사 281개가 통과했다. 로컬 Swift Testing 전체 실행은 234개 통과, 별도 볼륨·서버가 필요한 통합 검사 11개 건너뜀이었다. [홈 파일 태그 화면](ui-01-macos-home-file-tags.png)
