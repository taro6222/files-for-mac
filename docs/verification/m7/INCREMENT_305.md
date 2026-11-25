# M7 Increment 305 — 최신 후보 장시간 실행과 Windows 전송 중 상태 수집

상태: 진행 중. 수집 경로·로컬 보호 검증을 구현했으며 실제 Windows 실행 결과와 8시간 종료 판정은 남아 있다.

현재 앱 소스 `5284cb30b0d21a1033895558894f439599fd3d63`를 Git archive로 격리해 최적화 QA 빌드를 만들고 `full` 28,800초 시험을 시작했다. 실행은 `build/release-soak.cVt0iz`, 셸 PID 71077·앱 PID 71382다. 고정 바이너리 SHA-256은 `6d2cb840523fe2f70148b02a525dd509049b3130f0887360ee1bd44f8061ed9d`다. 실제 프로세스와 사이클 진행·감시 해제 보고서를 확인했다. 이전 `86be2b0`의 `build/release-soak.JDCzWA`는 별도로 유지한다. 두 실행은 같은 호스트에서 겹치므로 고립된 처리량 비교로 쓰지 않는다. 새 결과가 나오기 전 장시간 안정성을 통과로 표시하지 않는다.

현재 앱 소스의 두 CPU 전체 AppKit·Xcode 실행도 [별도 요청](https://github.com/taro6222/files-for-mac/actions/runs/45676291190)했다. 이전 `396866c` 실행과 구분하며 대기·실행 중 상태는 성공으로 집계하지 않는다.

남은 UI-10 원본 대조를 위해 Windows reference workflow에 `operation-progress` 범위를 추가했다. 기존 `operation-center` 완료·지우기 경로를 유지하면서 자체 fixture의 작은 파일 24,000개를 복사하고 다음 증거를 수집한다.

- 같은 표시 카드의 복사 중 제목·대상·진행 막대 또는 그래프·취소 메뉴, 실제 일부 목적 파일을 함께 확인한다.
- 진행 중·취소 메뉴·취소 후 카드를 PNG·접근성 XML로 저장한다.
- 활성 카드의 메뉴에서 실제 취소 명령을 실행하고, 취소 제목과 완료 제어 상태로 전환됐는지 기다린다.
- 취소 전후 원본 전체 파일명·크기·내용 SHA-256 manifest를 대조한다. 부분 대상이 전체보다 적고 후속 세 표본에서 변하지 않는지 확인한다. 부분 대상의 모든 파일이 완전하다는 보장은 이 검사에 포함하지 않는다.

원본의 [StatusCenter XAML](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/UserControls/StatusCenter/StatusCenter.xaml), [상태 변환](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Utils/StatusCenter/StatusCenterHelper.cs), [영문 문구](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Strings/en-US/Resources.resw)의 고정 SHA를 확인해 카드·진행·메뉴 ID와 제목을 연결했다. 완료 카드·다른 대상·숨은 카드·다른 행의 버튼을 활성 증거로 인정하지 않으며 실행 기회를 놓치면 실패 결과·마지막 화면을 보존한다.

로컬 Python 구문 검사와 보호 시험 5개가 통과했다. 보호 시험은 실제 Windows UI 성공 증거가 아니며 WinAppDriver 실행 후 원본 캡처와 기록을 다시 판정해야 한다. 이 단위는 앱 소스를 바꾸지 않았으므로 Swift·전체 AppKit을 반복 실행하지 않았다. 현재 앱의 검증은 304단계와 요청한 두 CPU 실행에 연결한다. 서명·공증 자격 증명과 실제 접근성 수용은 계속 미완료다.

## 업로드된 중간 원격 증거 확인

`396866c`의 실제 보고서를 다운로드했다. Apple Silicon 전체 AppKit 네 언어·외형 조합 각각 283개, 두 CPU 각각 제한 실행기 9개·수신 계약 53개·위치 미기록 SIGKILL 재기동 14개가 모두 통과했다. Apple Silicon 독립 APFS Spotlight 범위 4개도 통과했다. Intel 파일 작업·수신 단계는 이전 실패 지점을 넘어섰으며 전체 UI의 최종 결과는 진행 중이다. [원본 결과와 실행 상태](396866c-ci-verification.json)를 부분 결과로 보존했다.

ARM 네 실행의 전체 AppKit 표시 관찰값은 1.803–2.356초, 첫 표시는 22.0–32.7ms였다. 이는 서로 다른 언어·외형 네 실행이며 20회 p95 성능 기준 충족으로 표시하지 않는다.

더 최신 앱 소스 `5284cb3`의 Apple Silicon·Intel Xcode 빌드는 모두 성공했다. 같은 실행의 전체 UI·설치 검증은 별도 최종 판정한다. Windows 전송·취소 수집은 [실제 실행](https://github.com/taro6222/files-for-mac/actions/runs/45677056571)의 원본 빌드 단계이며 결과를 기다린다. 이 상태는 305단계 전체 완료를 뜻하지 않는다.
