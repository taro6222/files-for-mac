# M6 Increment 98 — 새 항목 선택

- 파일 메뉴, 컨텍스트 메뉴, 명령 팔레트 및 ⇧⌘I에서 **새 항목** 선택 창을 연다.
- 폴더, 빈 파일, 심볼릭 링크 중 하나를 고르면 기존 이름 입력 또는 링크 대상 선택 단계로 이어진다. 현재 위치와 활성 pane을 다시 확인한 후 생성 흐름을 시작한다.
- 고정 원본은 기본 유형과 등록 템플릿도 표시한다. macOS판의 이번 대응 범위는 기본 유형이며, F11의 사용자 템플릿 생성은 후속 범위다. [원본 유형 목록](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/ViewModels/Dialogs/AddItemDialog/AddItemDialogViewModel.cs)

## 검증

- Swift Testing 195개 통과.
- AppKit 자동 검증은 한국어·영어 × 밝게·어둡게 각 215개 통과. 실제 선택 창에서 빈 파일 유형을 선택하면 이름 입력 창이 열리는 흐름을 확인했다.
