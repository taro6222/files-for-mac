# M7 Increment 212 — Windows와 macOS 상하 분할 보기 대조

[Windows 실기 실행](https://github.com/taro6222/files-for-mac/actions/runs/43662902584)이 성공했다. Windows 빌드 26100 x64에서는 상하 분할 명령으로 같은 위치의 두 패널을 연 뒤 아래쪽에서 `Alpha`를 열었다. 접근성 트리에서 위쪽에는 공통 폴더의 다섯 항목, 아래쪽에는 `column-note.txt` 한 항목이 나타났다. 두 목록의 왼쪽 좌표가 같고 위쪽 목록이 아래쪽과 겹치지 않았다. 캡처 SHA-256은 실행 기록과 일치한다. [Windows 화면](ui-06-windows-reference-stacked.png) · [캡처 정보](windows-reference-stacked-4.2.9.json)

[macOS 화면](ui-06-macos-reference-stacked.png)은 좌우 분할에서 상하로 전환한 뒤 같은 두 폴더와 아래 패널의 활성 상태를 유지한다. Windows는 도구 모음에 활성 경로를 한 번 표시하고 아래 첫 행에 초점 테두리를 그린다. macOS는 패널마다 경로를 표시하고 아래 패널에 활성 테두리를 그린다. 탭 드롭의 Windows 실기 결과와 동일 창 크기에서의 시각 대조는 남아 있다.
