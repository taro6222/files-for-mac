# Windows 탐색 화면과 macOS 구조 대조

Windows의 비교 기준은 Files v4.2.9의 `99951c66928c4da714da8b1dd46039421182cbab`이다. 해당 커밋의 XAML과 Apple Silicon macOS 27.2 (26B123)에서 생성한 영어·밝은 테마 AppKit 캡처를 검토했다. 캡처는 900×572px의 창 콘텐츠를 담는다.

| 항목 | Windows 화면 정의 | macOS 캡처 및 동작 증거 |
|---|---|---|
| UI-01 홈 | 위젯 목록에서 빠른 접근, 드라이브, 네트워크 위치, 파일 태그, 최근 파일을 표시한다. [HomePage.xaml][home] | `home.png`에서 빠른 접근·드라이브·최근 위치를 확인했다. 최근 위치는 방문한 폴더 단위다. 마운트한 네트워크 볼륨은 홈의 네트워크 위치에서 연다. 이 영역은 드라이브 표시·펼침 설정을 공유한다. 파일 태그용 독립 홈 위젯은 대조 항목에 남는다. |
| UI-02 기본 탐색 | 외부 탐색 셸에서 사이드바, 내부 탐색 도구 모음, 선택한 탭의 콘텐츠를 배치한다. [MainPage.xaml][main] | `files-top.png`에서 사이드바·경로·보기 선택과 항목 수를 확인했다. AppKit의 `historySelection`과 `historyScroll`도 통과했다. |
| UI-03 상세 보기 | 이름·수정일·태그·Git 등 열과 표시 변경 메뉴가 있다. [DetailsLayoutPage.xaml][details] | `files-top.png`의 기본 열은 이름·수정일·종류·크기다. `autoFitColumns`, `gitCommitColumns`에서 추가 열과 너비 동작을 확인했다. |
| UI-04 그리드 | `GridView`로 다중 선택, 그룹 머리글, 드래그 및 스크롤 자리 표시자를 제공한다. [GridLayoutPage.xaml][grid] | `files-grid.png`에서 아이콘·이름·선택 상태를 확인했다. `gridSelectionIdentity`와 `gridGroupingSections`가 통과했다. |
| UI-05 컬럼 | `BladeView`가 초기 콘텐츠 프레임과 경계가 있는 개별 열을 배치한다. [ColumnsLayoutPage.xaml][columns] | `files-columns.png`에서 선택한 폴더의 계층별 열을 확인했다. `columnsHierarchy`, `columnsLeftNavigation` 및 폴더 열기 검사도 통과했다. |
| UI-06 분할 보기 | 탐색 셸의 시각 상태가 분할 중 활성 영역의 테두리 두께를 조정한다. [ModernShellPage.xaml][shell] | macOS는 활성 패널의 테두리와 좌우·상하 분할을 제공한다. [키보드 초점과 저장 상태](../verification/m7/INCREMENT_81.md) 및 [두 방향의 비율 복원](../verification/m7/INCREMENT_83.md)을 AppKit에서 검증한다. Windows 실행 화면과 탭 드롭 동작의 대조가 남아 있다. |
| UI-07 검색 | 탐색 툴바의 Omnibar가 검색 모드의 질의를 제출하고, 탐색 셸이 결과 화면에 검색 머리글을 표시한다. [NavigationToolbar.xaml][navigation] · [ModernShellPage.xaml][shell] | 별도 검색 창에 검색 방법, 범위, 메타데이터 필터와 결과 목록을 표시한다. `search.png`에서 결과 이름·위치·종류와 검색 방식별 상태를 확인했다. Spotlight 콘텐츠 검색은 [모든 인덱싱된 위치](../verification/m7/INCREMENT_78.md)를 선택할 수 있다. Windows 실행 캡처 대조가 남아 있다. |
| UI-08 정보·미리보기 | 정보 패널에 상세·미리보기 탭, 속성 스크롤 영역, 미리보기 콘텐츠와 로딩·오류 표시를 배치한다. [InfoPane.xaml][info] | macOS 정보 패널은 상세 속성과 내장 Quick Look을 제공한다. 다중 선택에서 [이전·다음 미리보기](../verification/m7/INCREMENT_79.md)를 사용할 수 있다. Windows 실행 화면과 Quick Look 확장별 콘텐츠 렌더링 대조가 남아 있다. |

macOS 캡처에서 발견한 상태 표시줄의 개발 단계 문구를 제거했다. 항목 수, 선택, 읽기 및 자동 갱신 상태는 상태 표시줄에 표시한다.

Windows 실행 화면을 동일 fixture·창 크기·테마로 캡처하는 작업이 남아 있다. 표는 XAML 구조와 macOS 실행 결과를 비교한 증거이며 화면 치수·픽셀 일치와 UI-01~UI-20 전체 상태는 검증 대기다.

[home]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/HomePage.xaml
[main]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/MainPage.xaml
[details]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/DetailsLayoutPage.xaml
[grid]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/GridLayoutPage.xaml
[columns]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/ColumnsLayoutPage.xaml
[navigation]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/UserControls/NavigationToolbar.xaml
[shell]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Shells/ModernShellPage.xaml
[info]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/UserControls/Pane/InfoPane.xaml
