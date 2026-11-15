# M7 Increment 210 — Windows 탭을 끌어 분할하는 동선 검증

Windows 원본에서 공통 폴더와 `Alpha`를 각각 탭으로 연다. `Alpha` 탭에서 공통 폴더 화면의 오른쪽 가장자리로 포인터를 끈다. 두 패널의 배치와 항목을 읽고, 이동한 원본 탭이 닫혀 전체 탭이 하나가 된 경우에만 캡처를 저장한다. [Windows 탭 드롭 처리](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Views/ShellPanesPage.xaml.cs)

실제 좌우 분할 접근성 트리에 탭 하나가 남은 경우를 검증했고 두 번째 탭이 존재하는 대조는 거부했다. Win32 모의 호출에서 시작 좌표, 버튼 누름, 목표 좌표와 버튼 해제를 확인했다. Windows 원본에서 실제 포인터 입력을 사용하는 검증은 GitHub Actions에서 실행한다. [Win32 포인터 이동](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setcursorpos) · [Win32 입력 전송](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)
