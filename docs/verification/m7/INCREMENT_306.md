# M7 Increment 306 — 원본 입력 초점 보호와 일괄 이름 변경 상태 수집

상태: 진행 중. 로컬 수집 보호 시험을 통과했으며 수정 후 Windows 실행과 화면 대조는 아직 완료하지 않았다.

## 전송 수집 실패와 수정

305단계의 [Windows 실행](https://github.com/taro6222/files-for-mac/actions/runs/45677056571)은 원본 빌드·설치를 통과했으나 전송 시작 전 주소 입력 검증에서 실패했다. 마지막 실제 PNG에는 목록 항목의 파일명 편집란에 주소의 끝부분이 들어간 상태가 보인다. 드라이버 로그의 주소 읽기 결과도 요청한 전체 목적지와 다르다. 이 실행을 전송·취소 성공으로 집계하지 않는다. 기존 실패 XML은 마지막으로 조회한 캐시이므로 PNG와 같은 시점의 초점 증거로 사용하지 않는다.

복사 목적지로는 표시된 `Workshop` 행을 선택하고 Enter로 진입한다. 파일 클립보드를 유지하면서 복사 후 주소를 입력하는 경합을 제거한다. 공통 주소·이름 입력 경로도 대상 편집란을 직접 클릭하고, 보이는 단일 입력란의 활성 상태와 실제 키보드 초점을 확인한 뒤 입력한다. 입력 후 텍스트 전체와 초점이 맞지 않으면 제출하지 않는다. 실패 시 새 접근성 트리를 요청하며, 새 조회 성공 여부를 별도 JSON에 기록해 오래된 트리와 실제 실패 화면을 혼동하지 않게 한다.

원본의 실패 캡처와 해시는 [기록](windows-reference-input-verification.json)에 보존한다. [실제 실패 화면](windows-transfer-input-failure.png)은 성공 기준 이미지가 아니다. Windows 러너의 자체 임시 fixture에 한정한 실행이었다.

## UI-12 일괄 이름 변경

새 `rename` 수집 범위는 공통 fixture의 복수 선택을 실제 접근성 트리로 확인한 뒤 F2를 누른다. [고정 원본 RenameAction](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/FileSystem/RenameAction.cs)의 F2 및 복수 선택 분기, [BulkRenameDialog](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/BulkRenameDialog.xaml)의 필드·버튼과 [ViewModel](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/ViewModels/Dialogs/BulkRenameDialogViewModel.cs)의 유효성 조건을 대조했다.

빈 이름의 비활성 확인 버튼, `invalid/name`의 오류 문구와 비활성 버튼, 정상 이름의 활성 버튼, 취소 후 원래 폴더를 수집한다. 입력값 조회와 버튼·오류의 표시 상태를 각각 확인하며, 잘못된 이름·확인 전 정상 입력·취소 후에 원본 파일명·크기·내용 manifest가 바뀌지 않았는지 검사한다. 실제 이름 변경 확정 동작을 검증했다고 주장하지 않는다.

현재 로컬 Python 구문 검사와 보호 시험 10개가 통과했다. 다른 컨트롤의 초점·숨은 입력란·중복 입력란은 입력 허가로 인정하지 않는다. 이름 오류는 비활성 버튼만으로 판정하지 않고 실제 오류 문구도 요구한다. 이 결과는 Windows UI 성공 증거가 아니며 두 수집 범위의 실제 실행이 필요하다. 앱 소스는 바꾸지 않았고, `5284cb3`의 장시간 시험 및 두 CPU 검증은 계속 유지한다.
