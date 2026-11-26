# M7 Increment 332 — Windows 압축 생성 상태 수집

상태: 진행 중. 수집 구현·로컬 보호 시험 완료, 실제 Windows 실행과 화면 대조는 미완료다. M7 출시는 미완료다.

UI-13의 고정 원본 실행 화면 대조가 남아 있어 `archive-create` 수집 범위를 추가한다. 기존 임시 러너에서 동일 fixture의 `preview.txt`를 선택하고 실제 명령 팔레트의 Create archive를 실행한다. 생성은 확정하지 않는다. 기본 이름·빈 이름·잘못된 이름·정상 입력·취소 후 폴더를 PNG와 접근성 트리로 기록한다.

이름 입력은 실제 단일 편집란의 표시·활성 상태·키보드 초점과 입력 후 전체 텍스트를 확인한다. 빈 문자열은 clear 뒤 실제 값을 읽고 빈 키 배열은 보내지 않는다. 압축 창은 FileNameBox·FileFormatSelector·CompressionLevelSelector·Create·Cancel을 함께 확인해 이름 변경 창으로 오인하지 않는다. 잘못된 이름은 비활성 버튼만으로 판정하지 않고 보이는 오류 팝업도 요구한다.

원본 fixture의 파일명·파일/디렉터리 종류·빈 폴더·내용 해시를 각 입력 후와 취소 후 대조한다. 생성 버튼은 누르지 않으며 생성·추출·암호/분할 압축·실제 포맷 왕복 성공을 주장하지 않는다. 기존 manifest 보호와 실패 시 PNG/새 접근성 트리 수집을 유지한다.

## 고정 원본 근거

모두 `99951c66928c4da714da8b1dd46039421182cbab`을 읽었다.

- [CreateArchiveDialog.xaml](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/CreateArchiveDialog.xaml): 이름·포맷·레벨, Create/Cancel과 유효성 바인딩.
- [CreateArchiveDialog.xaml.cs](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/CreateArchiveDialog.xaml.cs): 이름 유효성과 경고, primary 확인 후에만 CanCreate 설정.
- [CompressIntoArchiveAction](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Content/Archives/Compress/CompressIntoArchiveAction.cs): 선택 항목으로 이름을 준비하고 취소 시 압축을 실행하지 않는 경로.
- [OpenCommandPaletteAction](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Open/OpenCommandPaletteAction.cs): Ctrl+Shift+P 진입.

## 검증과 남은 항목

로컬 Python 보호 시험 16개와 구문 검사가 통과했다. workflow와 CLI의 9개 수집 범위가 일치한다. 숨김/누락/중복 포맷 컨트롤, 다른 대화상자, 경고 없는 비활성 버튼, 숨은 경고와 비활성 입력/취소를 성공으로 인정하지 않는지 확인했다. [코드·로그 해시](archive-reference-332-verification.json).

앱 소스·패키지 정의는 바꾸지 않았다. `81524f8`의 원격·8시간 진단은 그대로 유지하고 이 수집 코드 검증을 앱 UI 통과로 더하지 않는다. 실제 Windows 수집·Mac 대응 상태의 동일 fixture 대조·UI-13 전체 상태 수용이 필요하다. 최신 앱 원격/8시간·실제 입력/VoiceOver·지원 환경·외부 서비스·정식 서명/공증은 계속 미완료이며 사용자의 인증서와 notarytool 프로필은 준비 중이다.
