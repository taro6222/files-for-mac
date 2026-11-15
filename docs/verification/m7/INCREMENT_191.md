# M7 Increment 191 — 공유 시험 폴더로 탐색과 상세 보기 대조

`scripts/create-ui-reference-fixture.py`가 폴더 두 개, 파일 세 개와 고정된 수정 시각을 만든다. Windows 캡처도 이 시험 데이터를 사용한다. 홈 캡처 이후 Ctrl+L로 경로 편집기를 열고 입력 값을 읽어 확인한 뒤 폴더를 연다. 현재 경로와 다섯 항목이 일치한 다음에만 탐색 화면을 저장한다. 접근성 트리에 이름·수정일·종류·크기 네 열이 나타나면 같은 캡처를 상세 보기 근거로 표시한다.

macOS 영어·밝은 테마 AppKit 검증은 공통 폴더에 들어가 다섯 항목과 상세 보기의 네 열을 확인했다. 전체 검사 273개가 통과했고 [macOS 폴더 화면](ui-02-03-macos-reference-folder.png)을 검토했다. Windows 탐색은 실제 홈 접근성 트리와 모의 폴더 응답에서 검증했다.

[Windows 실행](https://github.com/taro6222/files-for-mac/actions/runs/43656147792)이 성공했다. Windows 빌드 26100 x64에서 기준 패키지를 열고 경로 입력으로 공유 fixture에 이동했다. 디렉터리 두 개와 파일 세 개의 이름 및 Name, Date modified, Type, Size를 접근성 트리로 대조했다. [Windows 폴더 화면](ui-02-03-windows-reference-folder.png) · [패키지·캡처 식별 정보](windows-reference-folder-4.2.9.json)

두 화면에서 폴더가 파일보다 위에 있고 이름 순서가 같으며 파일 크기는 22·24·26바이트로 일치한다. Windows는 경로를 경로 조각으로 보여 주며 기본 태그 열과 폴더의 개별 크기 조회를 표시했다. macOS는 경로 입력 필드와 기본 네 열을 보여 주며 폴더 크기는 비어 있다. 캡처는 Windows 1,920×1,032px, macOS 1,800×1,136px이며 Windows 화면에는 첫 폴더의 초점과 툴팁이 포함됐다. 동일 창 크기와 동일 상호작용 상태의 시각 기준 확정은 남아 있다.
