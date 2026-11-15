# M7 Increment 217 — Windows와 macOS의 공통 폴더 검색 대조

[Windows 원본 실행](https://github.com/taro6222/files-for-mac/actions/runs/43664395598)에서 고정 SHA `99951c66928c4da714da8b1dd46039421182cbab`의 Files가 `column-note` 질의에 `Alpha/column-note.txt` 한 개를 반환했다. Windows는 탐색 창에 질의 제목과 이름·태그·경로·수정일·종류·크기 열을 표시한다. macOS는 별도 검색 창에 검색 방법·범위·메타데이터 필터와 이름·위치·종류 열을 표시하며 같은 하위 파일을 찾았다. [Windows 검색](ui-07-windows-reference-search.png) · [macOS 검색](ui-07-macos-search-size-inputs.png)

Windows 실행은 검색 캡처를 저장한 뒤 같은 폴더 경로를 다시 입력했을 때 검색 결과 화면에 머물러 탭 이동 단계에서 중단됐다. 캡처의 접근성 트리에서 활성 상태의 뒤로 버튼을 확인했다. 드라이버는 이 버튼으로 첫 탭의 폴더를 복원하고, 검색 검증에서는 파일명과 전체 경로가 정확한 결과 행 한 개를 요구한다.

Python 구문 검사와 PNG SHA-256 대조를 통과했다. 저장된 접근성 트리의 검색 결과는 승인했고 폴더 화면, 결과 경로 변경, 중복 결과 행은 거부했다. 뒤로 버튼 클릭과 탭 드롭은 Windows에서 다시 실행한다.
