# M7 Increment 206 — Windows와 macOS 좌우 분할 보기 대조

[Windows 실기 실행](https://github.com/taro6222/files-for-mac/actions/runs/43661277607)이 성공했다. Windows 빌드 26100 x64의 Files 4.2.9에서 공통 폴더를 좌우로 분할하고 오른쪽 패널에서 `Alpha`를 열었다. 왼쪽에 공통 폴더의 다섯 항목, 오른쪽에 `column-note.txt`가 표시되는 것을 접근성 트리로 확인했다. 캡처 SHA-256이 실행 기록과 일치한다. [Windows 분할 화면](ui-06-windows-reference-dual-pane.png) · [캡처 정보](windows-reference-dual-pane-4.2.9.json)

[macOS 분할 화면](ui-06-macos-reference-dual-pane.png)에서 같은 두 목록과 오른쪽 활성 패널 표시를 확인했다. Windows 원본은 공통 도구 모음에 활성 패널의 경로를 표시하고 오른쪽 첫 행에 초점 테두리를 그린다. macOS는 각 패널에 탐색 도구 모음을 표시하고 활성 패널을 파란색 테두리로 표시한다. 원본 캡처는 1,920×1,032px, macOS 캡처는 2,500×1,200px이다. 동일 창 크기에서의 시각 대조, 상하 분할, 탭을 끌어 분할하는 Windows 실행 시험은 남아 있다.
