# M7 Increment 197 — Windows 그리드 캡처와 컬럼 검증 보정

[Windows 실행](https://github.com/taro6222/files-for-mac/actions/runs/43657989595)에서 기준 Windows Files의 그리드에 공통 폴더의 다섯 항목이 나타나는 것을 확인했다. 캡처 SHA-256이 실행 기록과 일치한다. [Windows 그리드](ui-04-windows-reference-grid.png) · [캡처 식별 정보](windows-reference-grid-4.2.9.json)

두 앱에서 다섯 항목의 이름과 순서가 같다. Windows는 큰 아이콘과 `Alpha` 폴더의 내용 미리보기를 표시했다. macOS는 더 작은 아이콘과 문서 미리보기를 표시했다. 창 크기와 초점 상태가 달라 아이콘 크기의 수치 대조는 남아 있다. [macOS 그리드](ui-04-macos-reference-grid.png)

같은 Windows 실행의 컬럼 진단 화면과 접근성 트리에서 `Alpha`와 `column-note.txt`가 인접한 위치에 표시됐다. 이때 원본은 작업 폴더의 상위 경로까지 다섯 컬럼으로 펼쳤다. 전체를 두 컬럼으로 가정했던 자동 검증을 바꿔 공통 폴더의 `Alpha`, `Workshop`과 선택한 폴더의 하위 파일이 인접한 두 컬럼에 있는지 확인한다. 실제 Windows 접근성 트리를 재생해 통과를 확인했고 컬럼 사이에 다른 항목을 삽입한 대조는 거부했다. 자동 캡처를 다시 실행한다.
