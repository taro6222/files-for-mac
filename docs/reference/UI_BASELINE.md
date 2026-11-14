# Windows 탐색 화면과 macOS 구조 대조

Windows의 비교 기준은 Files v4.2.9의 `99951c66928c4da714da8b1dd46039421182cbab`이다. 해당 커밋의 XAML과 Apple Silicon macOS 27.2 (26B123)에서 생성한 영어·밝은 테마 AppKit 캡처를 검토했다. 캡처는 900×572px의 창 콘텐츠를 담는다.

| 항목 | Windows 화면 정의 | macOS 캡처 및 동작 증거 |
|---|---|---|
| UI-01 홈 | 위젯 목록에서 빠른 접근, 드라이브, 네트워크 위치, 파일 태그, 최근 파일을 표시한다. [HomePage.xaml][home] | `home.png`에서 빠른 접근·드라이브·최근 위치를 확인했다. 최근 위치는 방문한 폴더 단위다. 네트워크 위치·태그용 독립 홈 위젯은 대조 항목에 남는다. |
| UI-02 기본 탐색 | 외부 탐색 셸에서 사이드바, 내부 탐색 도구 모음, 선택한 탭의 콘텐츠를 배치한다. [MainPage.xaml][main] | `files-top.png`에서 사이드바·경로·보기 선택과 항목 수를 확인했다. AppKit의 `historySelection`과 `historyScroll`도 통과했다. |
| UI-03 상세 보기 | 이름·수정일·태그·Git 등 열과 표시 변경 메뉴가 있다. [DetailsLayoutPage.xaml][details] | `files-top.png`의 기본 열은 이름·수정일·종류·크기다. `autoFitColumns`, `gitCommitColumns`에서 추가 열과 너비 동작을 확인했다. |
| UI-04 그리드 | `GridView`로 다중 선택, 그룹 머리글, 드래그 및 스크롤 자리 표시자를 제공한다. [GridLayoutPage.xaml][grid] | `files-grid.png`에서 아이콘·이름·선택 상태를 확인했다. `gridSelectionIdentity`와 `gridGroupingSections`가 통과했다. |
| UI-05 컬럼 | `BladeView`가 초기 콘텐츠 프레임과 경계가 있는 개별 열을 배치한다. [ColumnsLayoutPage.xaml][columns] | `files-columns.png`에서 선택한 폴더의 계층별 열을 확인했다. `columnsHierarchy`, `columnsLeftNavigation` 및 폴더 열기 검사도 통과했다. |

macOS 캡처에서 발견한 상태 표시줄의 개발 단계 문구를 제거했다. 항목 수, 선택, 읽기 및 자동 갱신 상태는 상태 표시줄에 표시한다.

Windows 실행 화면을 동일 fixture·창 크기·테마로 캡처하는 작업이 남아 있다. 표는 XAML 구조와 macOS 실행 결과를 비교한 증거이며 화면 치수·픽셀 일치와 UI-01~UI-20 전체 상태는 검증 대기다.

[home]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/HomePage.xaml
[main]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/MainPage.xaml
[details]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/DetailsLayoutPage.xaml
[grid]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/GridLayoutPage.xaml
[columns]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/ColumnsLayoutPage.xaml
