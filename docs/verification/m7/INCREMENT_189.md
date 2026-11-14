# M7 Increment 189 — Windows와 macOS 홈 실행 화면 대조

[Windows 실행](https://github.com/taro6222/files-for-mac/actions/runs/43654289046)에서 기준 원본 `99951c66928c4da714da8b1dd46039421182cbab`을 패키징해 Windows 빌드 26100 x64에 설치했다. WinAppDriver가 해당 패키지의 창에 연결해 1,920×1,032px 화면을 캡처했다. 캡처 파일 해시를 실행 보고서와 대조했다. UI Automation에는 Quick access, Drives, Network locations, Recent files 버튼과 사이드바의 Tags·Settings 항목이 나타났다. [Windows 홈](ui-01-windows-home-v4.2.9.png) · [캡처 식별 정보](windows-home-4.2.9.json)

macOS의 소스 `07c31930a5384ed98a269665c28efd98ca7818a4`로 실행한 AppKit의 영어·밝은 테마 홈 화면과 대조했다. macOS 스크린샷은 1,800×1,136px이다. 두 화면 모두 빠른 접근과 드라이브를 표시하고 네트워크 위치는 접힌 상태였다. Windows는 빠른 접근과 드라이브를 여러 열의 카드에 배치하며, macOS는 세로 버튼과 전체 너비 드라이브 카드를 사용한다. Windows Recent files는 파일 항목을 다루고, macOS Recent Locations는 방문한 폴더를 다룬다. Windows의 기본 실행에서 홈 태그 위젯은 나타나지 않았으며 사이드바에 태그 섹션이 있었다. [macOS 홈](ui-01-macos-home-07c3193.png)

이번 비교의 창 크기·fixture는 서로 다르다. 다른 화면과 상태, 동일 크기·fixture의 판정은 계속 추적한다.

WinAppDriver가 반환한 XML에는 UTF-16 선언이 있었다. 저장할 때 실제 인코딩과 일치하는 UTF-8 XML을 직렬화하도록 수정했고, 내려받은 실제 트리를 입력해 저장된 XML을 바이트 파일로 다시 파싱하고 위젯 이름을 대조했다.
