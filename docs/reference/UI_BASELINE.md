# Windows 화면과 macOS 구조 대조

Windows의 비교 기준은 Files v4.2.9의 `99951c66928c4da714da8b1dd46039421182cbab`이다. 해당 커밋의 XAML과 Apple Silicon macOS 27.2 (26B123)에서 생성한 영어·밝은 테마 AppKit 캡처를 검토했다. 탐색 창 캡처는 900×572px이며 보조 창은 각 창의 콘텐츠 크기를 사용한다.

| 항목 | Windows 화면 정의 | macOS 캡처 및 동작 증거 |
|---|---|---|
| UI-01 홈 | 위젯 목록에서 빠른 접근, 드라이브, 네트워크 위치, 파일 태그, 최근 파일을 표시한다. [HomePage.xaml][home] | [빠른 접근·드라이브 카드](../verification/m7/INCREMENT_190.md)는 창 너비에 맞춰 줄을 바꾼다. [최근 파일](../verification/m7/INCREMENT_192.md)은 앱에서 연 파일을 보여 주며 최근 위치는 방문한 폴더를 보여 준다. [네트워크 위치](../verification/m7/INCREMENT_184.md)는 마운트한 공유를 연다. [파일 태그](../verification/m7/INCREMENT_196.md)는 Spotlight가 색인한 항목을 Finder 태그별로 표시한다. |
| UI-02 기본 탐색 | 외부 탐색 셸에서 사이드바, 내부 탐색 도구 모음, 선택한 탭의 콘텐츠를 배치한다. [MainPage.xaml][main] | `files-top.png`에서 사이드바·경로·보기 선택과 항목 수를 확인했다. AppKit의 `historySelection`과 `historyScroll`도 통과했다. |
| UI-03 상세 보기 | 이름·수정일·태그·Git 등 열과 표시 변경 메뉴가 있다. [DetailsLayoutPage.xaml][details] | [기본 상세 열](../verification/m7/INCREMENT_198.md)은 이름·Finder 태그·수정일·종류·크기다. `autoFitColumns`, `gitCommitColumns`에서 추가 열과 너비 동작을 확인했다. |
| UI-04 그리드 | `GridView`로 다중 선택, 그룹 머리글, 드래그 및 스크롤 자리 표시자를 제공한다. [GridLayoutPage.xaml][grid] | `files-grid.png`에서 아이콘·이름·선택 상태를 확인했다. `gridSelectionIdentity`와 `gridGroupingSections`가 통과했다. |
| UI-05 컬럼 | `BladeView`가 초기 콘텐츠 프레임과 경계가 있는 개별 열을 배치한다. [ColumnsLayoutPage.xaml][columns] | `files-columns.png`에서 선택한 폴더의 계층별 열을 확인했다. `columnsHierarchy`, `columnsLeftNavigation` 및 폴더 열기 검사도 통과했다. |
| UI-06 분할 보기 | 탐색 셸의 시각 상태가 분할 중 활성 영역의 테두리 두께를 조정한다. [ModernShellPage.xaml][shell] | macOS는 활성 패널의 테두리와 좌우·상하 분할을 제공한다. [키보드 초점과 저장 상태](../verification/m7/INCREMENT_81.md) 및 [두 방향의 비율 복원](../verification/m7/INCREMENT_83.md)을 AppKit에서 검증한다. [보조 패널의 읽기 중단과 재시도](../verification/m7/INCREMENT_111.md)를 검증한다. 양쪽 앱의 [좌우](../verification/m7/INCREMENT_206.md)·[상하](../verification/m7/INCREMENT_212.md) 분할 화면을 대조했다. [탭 드롭](../verification/m7/INCREMENT_236.md)은 일반 권한 Windows 실행에서 확인해야 한다. |
| UI-07 검색 | 탐색 툴바의 Omnibar가 검색 모드의 질의를 제출하고, 탐색 셸이 결과 화면에 검색 머리글을 표시한다. [NavigationToolbar.xaml][navigation] · [ModernShellPage.xaml][shell] | 별도 검색 창에 검색 방법, 범위, 메타데이터 필터와 결과 목록을 표시한다. Spotlight 콘텐츠 검색은 [모든 인덱싱된 위치](../verification/m7/INCREMENT_78.md)를 선택할 수 있다. 공통 폴더에서 두 앱이 동일한 하위 파일 한 개를 반환했다. [실행 화면 대조](../verification/m7/INCREMENT_217.md) |
| UI-08 정보·미리보기 | 정보 패널에 상세·미리보기 탭, 속성 스크롤 영역, 미리보기 콘텐츠와 로딩·오류 표시를 배치한다. [InfoPane.xaml][info] | [두 앱의 실행 화면](../verification/m7/INCREMENT_224.md)에서 같은 파일의 상세와 미리보기 본문을 대조했다. macOS는 [생성일과 태그 편집·속성 바로가기](../verification/m7/INCREMENT_226.md), [Git 상태](../verification/m7/INCREMENT_229.md), [폴더 미리보기 불가 상태](../verification/m7/INCREMENT_218.md), [본문 스크롤](../verification/m7/INCREMENT_222.md), 다중 선택의 [이전·다음 미리보기](../verification/m7/INCREMENT_79.md)를 제공한다. [설치 앱의 PNG와 PDF 미리보기](../verification/m7/INCREMENT_259.md)를 실제 창에서 확인했다. Windows와 동일 포맷의 화면 대조 및 대용량·손상 파일 검증이 남아 있다. |
| UI-09 속성 창 | 속성 페이지에 일반 정보, 보안, 해시, 서명 등 항목별 화면을 제공한다. 해시 화면에서 여러 알고리즘을 표시한다. [MainPropertiesPage.xaml][properties] · [HashesPage.xaml][hashes] · [일반·해시 실행 화면](../verification/m7/INCREMENT_238.md) | macOS 속성 창에서 경로, 크기, 날짜, 소유자·권한, Finder 태그, CRC32·MD5·SHA-1·SHA-256·SHA-384·SHA-512와 코드 서명 정보를 제공한다. AppKit 팝업에서 알고리즘을 선택해 해시값이나 다른 파일과 비교한다. [해시 비교 검증](../verification/m7/INCREMENT_152.md) [최소 창 크기의 스크롤과 하단 버튼 접근](../verification/m7/INCREMENT_97.md)을 검증했다. 별도 시트에서 POSIX 권한을 편집하고 macOS 텍스트 형식으로 확장 ACL을 편집한다. [권한 검증](../verification/m7/INCREMENT_153.md) [확장 ACL 검증](../verification/m7/INCREMENT_154.md) [계정 이름 기반 규칙 추가](../verification/m7/INCREMENT_155.md)를 제공한다. [macOS 사용자·그룹 목록](../verification/m7/INCREMENT_156.md)을 제공한다. [같은 24바이트 파일의 속성·SHA-256 실행 화면](../verification/m7/INCREMENT_240.md)을 두 앱에서 대조했다. [속성 창의 이름 편집](../verification/m7/INCREMENT_241.md)에서 이름 변경, 충돌 보호, 확장자 변경 취소를 검증했다. [Windows와 macOS의 보안·서명 실행 화면](../verification/m7/INCREMENT_244.md)에서 플랫폼별 권한과 서명 표시를 확인했다. [macOS 중첩 앱의 정상·무효 서명 상태와 진단 표시](../verification/m7/INCREMENT_251.md)를 확인했다. [Windows 고급 보안 실행](../verification/m7/INCREMENT_256.md)에서 소유자와 권한 행을 실제 ACL과 대조했다. Windows의 고급 권한 편집과 macOS 인증서 기반 서명 검증은 남아 있다. |
| UI-10 작업 센터 | [실제 전송·취소](../verification/m7/INCREMENT_308.md)에서 24,000개 복사 중 바이트·진행률·취소 메뉴·terminal 카드를 확인했다. 원본 digest와 남은 1,429개의 알려진 내용도 일치했다. [StatusCenter.xaml][status-center] | Mac은 항목 수·현재 단계·취소와 검증 후 결과를 제공한다. [복사 중 논리 바이트](../verification/m7/INCREMENT_311.md)는 현재 원본 파일·폴더의 데이터 바이트·예정량·백분율과 충분한 시간 동안 측정한 평균 논리 속도를 표시한다. 클론은 완료된 파일의 논리 크기로 집계한다. [교차 볼륨 이동](../verification/m7/INCREMENT_312.md)에도 같은 바이트 문구를 연결했다. 같은 볼륨 rename은 바이트 전송을 표시하지 않는다. [병합 현재 항목 데이터](../verification/m7/INCREMENT_316.md)와 [여러 원본 복사의 전체 데이터 합계](../verification/m7/INCREMENT_318.md)를 연결했다. [병합 선택 전체 합계](../verification/m7/INCREMENT_319.md)도 연결했다. 이동 전체 합계와 전체 상태·실제 접근성 대조는 계속 진행한다. |
| UI-11 충돌 | 원본과 대상의 이름·폴더를 한 행에 배치하고 항목별 또는 전체 충돌에 이름 생성·교체·건너뛰기를 적용한다. [FilesystemOperationDialog.xaml][conflict] | macOS의 복사·이동 대화상자에서는 두 항목의 상세 정보와 [텍스트](../verification/m7/INCREMENT_90.md)·[이미지·PDF 미리보기](../verification/m7/INCREMENT_91.md)를 보고 정책을 선택한다. 파일 작업 시험에서 긴 미리보기의 스크롤과 건너뛰기 후 두 파일 보존을 확인했다. |
| UI-12 일괄 이름 변경 | [실제 빈 이름·오류·정상·취소](../verification/m7/INCREMENT_308.md)에서 확인 버튼의 활성 조건과 오류 문구, 취소 후 파일 내용·다섯 원래 이름을 확인했다. [BulkRenameDialog.xaml][rename] | [모드별 입력 안내](../verification/m7/INCREMENT_308.md)는 빈 값·잘못된 번호·번호 범위·기본 이름 문자·정규식 오류를 안내하고 유효할 때만 미리보기를 허용한다. [읽기 전용 계획](../verification/m7/INCREMENT_103.md)에서 결과·충돌을 보고 실행 직전에 다시 검증한다. 실제 키보드·동일 전체 창 조건·VoiceOver 수용은 남아 있다. |
| UI-13 압축 | 생성 창에 포맷·압축 수준·분할 및 암호 옵션, 추출 창에 대상 경로·인코딩·암호 입력을 배치한다. [CreateArchiveDialog.xaml][archive-create] · [DecompressArchiveDialog.xaml][archive-extract] | `archive.png`와 `archive-creation.png`는 내부 목록과 생성 결과를 보여 준다. AppKit에서 생성, 추출, 배치 방식과 취소를 확인했다. 포맷별 편집·분할·암호 옵션은 지원 범위 차이가 있다. [Windows 생성 창의 입력·취소 상태 수집](../verification/m7/INCREMENT_332.md)을 추가했으며 실제 실행·동일 상태 대조는 진행 중이다. |
| UI-14 연결 | 홈에 네트워크 위치를 표시하고 탐색 도구의 경로 제출에서 FTP를 처리한다. [NetworkLocationsWidget.xaml][network] · [NavigationToolbarViewModel.cs][navigation-model] | `remote-connections.png`는 등록된 프로필과 인증 입력, `remote-browser.png`는 목록과 이동을 보여 준다. 호스트 신뢰와 실제 서버 인증·오프라인 상태의 실행 대조가 남아 있다. |
| UI-15 Git | 상세 보기에서 Git 저장소일 때 상태·커밋 열을 제공하고 동기화 명령으로 작업을 요청한다. [DetailsLayoutPage.xaml][details] · [GitSyncAction.cs][git-sync] | `git-status.png`와 `git-file-column.png`에서 상태 패널과 열을 확인했다. AppKit에서 패널의 접근성 이름과 명령, 커밋 열 갱신을 확인했다. [병합 충돌 상태](../verification/m7/INCREMENT_108.md)는 상태 패널과 상세 열에 표시한다. 실제 인증과 Windows 충돌 화면 대조가 남아 있다. |
| UI-16 명령 팔레트 | 탐색 도구 모음의 Omnibar에 팔레트 모드를 두고 검색어와 제안 목록을 연결한다. [NavigationToolbar.xaml][navigation] | `command-palette.png`는 별도 검색 창의 명령과 단축키 표시를 보여 준다. AppKit에서 메뉴 인덱스, 검색, 입력 초점을 검증했다. 실행 불가 이유와 전체 키보드 동선 대조가 남아 있다. |
| UI-17 설정 | 설정 탐색 페이지와 검색 결과의 빈 상태를 제공한다. [SettingsPage.xaml][settings] | macOS는 응용 프로그램 메뉴에서 각 설정 창을 연다. `general-settings.png`와 `appearance-settings.png`를 확인했고, 최소 창 크기에서 일반 설정 스크롤과 하단 조작을 검사했다. |
| UI-18 휴지통 | 휴지통에서 전체 복원과 비우기 명령을 제공한다. [RestoreAllRecycleBinAction.cs][trash-restore] · [EmptyRecycleBinAction.cs][trash-empty] | AppKit에서 Finder 휴지통으로 넘기는 경로를 확인했다. macOS의 시스템 휴지통 전체 목록·전체 복원과 앱 자체 이동 기록의 경계는 [플랫폼 차이](PLATFORM_DIFFERENCES.md)에 있다. |
| UI-19 사용자 지정 | 툴바 모드·추가/사용 가능 항목·레이블 표시 및 초기화, 사이드바 항목 순서 저장을 제공한다. [ToolbarCustomizationPage.xaml][toolbar-settings] · [ReorderSidebarItemsDialog.xaml][sidebar-settings] | `toolbar-settings.png`에서 표시와 순서를 조작하는 컨트롤을 확인했다. AppKit에서 순서 및 표시 저장, 앱 배경 적용, 폴더 보기 관리·초기화를 검사했다. |
| UI-20 최초 실행·접근 오류 | 상세 보기에 위치 오류의 제목·사유·표시 여부가 연결되며 접근 거부와 다른 실패를 구분한다. [DetailsLayoutPage.xaml][details] · [ShellViewModel.cs][shell-model] | `permission-error.png`의 재시도와 폴더 선택을 확인했다. AppKit에서 권한 거부, 존재하지 않는 경로, 오류 복구 버튼과 문구를 검사했다. 운영체제 권한 요청이 발생하는 최초 실행 동선의 대조가 남아 있다. |

macOS 캡처에서 발견한 상태 표시줄의 개발 단계 문구를 제거했다. 항목 수, 선택, 읽기 및 자동 갱신 상태는 상태 표시줄에 표시한다.

[UI-01 홈 실행 화면 대조](../verification/m7/INCREMENT_189.md)에서 Windows와 macOS의 기본 홈 레이아웃과 위젯을 확인했다. 동일 fixture·창 크기의 화면, UI-02~UI-20 및 적용 상태별 시각·동작 검증은 정식 출시 게이트에 남아 있다.

[UI-02·03 공통 폴더 실행 화면](../verification/m7/INCREMENT_191.md)에서 양쪽의 파일 순서·크기·기본 열을 확인했다. macOS 상세 보기의 크기 열에 [개별 폴더 크기 조회](../verification/m7/INCREMENT_193.md)를 추가하고 원본과 같이 [태그 열을 기본 표시](../verification/m7/INCREMENT_198.md)한다. 탐색 경로의 표현이 다르며 같은 창 크기와 상호작용 상태의 비교가 남아 있다.

[UI-04·05 공통 폴더의 그리드·컬럼 검증](../verification/m7/INCREMENT_195.md)에서 macOS의 다섯 항목과 `Alpha` 선택으로 열린 두 번째 컬럼을 확인했다. Windows 캡처에도 같은 시험 항목과 컬럼 확인을 추가했다.

[Windows 그리드](../verification/m7/INCREMENT_197.md)와 [컬럼 보기 실행 화면](../verification/m7/INCREMENT_201.md)을 macOS 화면과 대조했다. macOS 컬럼 보기에도 [상위 경로 표시](../verification/m7/INCREMENT_202.md), [좌우 방향키 이동 및 선택 복원](../verification/m7/INCREMENT_204.md), [개별 컬럼 너비 조절](../verification/m7/INCREMENT_205.md)을 적용했다.

[UI-06 좌우 분할 실행 화면](../verification/m7/INCREMENT_206.md)은 Windows와 macOS에서 공통 폴더와 `Alpha` 하위 항목을 서로 다른 패널에 표시한다. 양쪽의 도구 모음 구성과 초점 표시를 대조했다.

[UI-06 상하 분할 실행 화면](../verification/m7/INCREMENT_212.md)은 두 앱에서 공통 폴더와 `Alpha` 하위 항목을 위아래로 표시하는 동작을 대조한다.

[UI-06 Windows 탭 드롭 검증 경로](../verification/m7/INCREMENT_210.md)는 두 탭을 연 뒤 원본 탭을 오른쪽 패널로 이동하는 동선을 검사한다.

[UI-07 공통 폴더 검색 검증](../verification/m7/INCREMENT_213.md)은 두 앱에서 하위 폴더의 동일한 파일을 찾는 동선을 대조한다.

[home]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/HomePage.xaml
[main]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/MainPage.xaml
[details]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/DetailsLayoutPage.xaml
[grid]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/GridLayoutPage.xaml
[columns]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Layouts/ColumnsLayoutPage.xaml
[navigation]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/UserControls/NavigationToolbar.xaml
[shell]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Shells/ModernShellPage.xaml
[info]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/UserControls/Pane/InfoPane.xaml
[properties]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Properties/MainPropertiesPage.xaml
[hashes]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Properties/HashesPage.xaml
[status-center]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/UserControls/StatusCenter/StatusCenter.xaml
[conflict]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/FilesystemOperationDialog.xaml
[rename]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/BulkRenameDialog.xaml
[archive-create]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/CreateArchiveDialog.xaml
[archive-extract]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/DecompressArchiveDialog.xaml
[network]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/UserControls/Widgets/NetworkLocationsWidget.xaml
[navigation-model]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/ViewModels/UserControls/NavigationToolbarViewModel.cs
[git-sync]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Git/GitSyncAction.cs
[settings]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Settings/SettingsPage.xaml
[trash-restore]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/FileSystem/RestoreAllRecycleBinAction.cs
[trash-empty]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/FileSystem/EmptyRecycleBinAction.cs
[toolbar-settings]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/Settings/ToolbarCustomizationPage.xaml
[sidebar-settings]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/ReorderSidebarItemsDialog.xaml
[shell-model]: https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/ViewModels/ShellViewModel.cs
