# M7 Increment 308 — 일괄 이름 변경 입력 안내와 실제 원본 상태 대조

상태: 로컬 구현·검증 통과. 새 입력 구성요소의 두 CPU 원격 수용과 M7 정식 출시는 진행 중이다.

Mac의 일괄 이름 변경 입력창은 빈 값으로 미리보기를 누르면 계획 없이 닫혔다. 이제 입력창을 유지하고 필요한 값을 안내하며 유효한 경우에만 미리보기를 활성화한다. 번호 매기기에서는 기본 이름의 금지 문자·시작 번호·선택 개수에 따른 정수 범위를, 정규식에서는 구문을 확인한다. 입력 변경과 모드 전환에 즉시 반응하고 확인 응답을 직접 보내도 값을 다시 검사한다. 실제 파일명·충돌·원본 상태는 기존 읽기 전용 계획과 실행 직전 재검증을 계속 사용한다.

입력 확인에는 파일 탐색이나 전체 이름 계획 생성을 사용하지 않는다. 현재 선택 수와 입력값만 검사해 입력 중 파일 작업을 시작하지 않는다. 버튼 상태와 이유를 텍스트로 제공한다. macOS는 미리보기 후 실행을 확인하는 두 단계이며 Windows의 직접 이름 변경 버튼과 구분한다.

## 로컬 검증

- 최종 Debug·Release 빌드 성공. 고정 Debug SHA-256 `d7709df4adf94c7f0295cbafbfea8465a1419e89bcf49f547680d1563dbc6241`.
- Swift 322개 보고: 성공 304개·별도 환경 건너뜀 18개. FilesCore는 바꾸지 않았다. 최종 DEBUG 캡처 배경 보완 전의 동일 코어 회귀다.
- 한국어/영어 × 밝게/어둡게 네 조합 각각 파일 작업 UI 78개와 전체 UI 283개 통과.
- 기존 잘못된 이름 변경 차단 검사에 입력 구성요소의 13개 진단을 함께 연결했다. 빈 값·잘못된 번호·범위 초과·금지 문자·잘못된 정규식·정상 번호/정규식·취소와 네 캡처가 모두 통과했다. 기존 검사 개수에 이 진단 수를 더해 부풀리지 않는다.
- [원본 결과·소스·바이너리·로그 해시](batch-rename-input-verification.json), [빈 입력](batch-input-ko-light-empty.png), [번호 오류](batch-input-en-light-invalid-number.png), [정규식 오류](batch-input-en-light-invalid-regex.png), [정상 입력](batch-input-en-light-valid.png).

프로그램 방식의 실제 AppKit 입력 구성요소 검증이다. 실제 키 입력·마우스·VoiceOver, Windows와 동일한 전체 창·fixture·초점·배율의 시각 수용은 남아 있다. 앞서 통과한 원격 앱 소스 `5284cb3`에는 이 새 입력 구성요소가 없으므로 새 소스의 원격 검증을 별도로 진행한다. 실행 중인 8시간 두 건도 각 기존 소스의 기준 실행으로 유지한다.

## Windows 실제 전송·취소

[실제 실행](https://github.com/taro6222/files-for-mac/actions/runs/45679664842)이 통과했다. 24,000개 파일·24,576,000바이트의 자체 fixture를 복사해 357개가 생긴 활성 카드에서 바이트·진행률을 확인했다. 실제 메뉴로 취소한 후 대상은 1,429개·1,463,296바이트에서 안정됐고 원본 전체의 이름·크기·내용 digest는 그대로였다. 원본 digest와 남은 대상 digest를 생성 규칙으로 독립 재계산해 각각 전체 fixture와 0~1,428번 파일의 정확한 바이트에 일치하는 것도 확인했다. 이 실행 결과를 모든 취소 대상의 완전성 보장으로 확대하지 않는다.

[진행 중](windows-transfer-active.png) · [취소 메뉴](windows-transfer-cancel-menu.png) · [취소 완료](windows-transfer-cancelled.png). 취소 명령부터 terminal 카드 관찰까지 3.468초는 WinAppDriver·폴링을 포함한다. 앱의 입력 피드백 시간이나 Mac과의 취소 성능 비교로 쓰지 않는다. Mac의 전송 중 전체 바이트 합·속도 표시와 해당 상태의 전체 대조는 여전히 열린 항목이다.

## Windows 실제 이름 입력·취소

[별도 실제 실행](https://github.com/taro6222/files-for-mac/actions/runs/45679673351)도 통과했다. 공통 fixture의 다섯 항목을 선택하고 빈 이름·잘못된 이름·정상 이름·취소 상태를 수집했다. 빈 값과 `invalid/name`에서는 Rename이 비활성화됐고 잘못된 이름 문구도 표시됐다. 정상 이름에서는 활성화됐다. 취소 후 네 일반 파일·96바이트의 전체 digest가 유지됐고, 마지막 실제 접근성 트리에서 빈 `Workshop` 폴더를 포함한 원래 다섯 이름이 정확히 유지됐다.

[빈 이름](windows-rename-empty.png) · [오류](windows-rename-invalid.png) · [정상](windows-rename-valid.png) · [취소](windows-rename-cancelled.png). 두 실행은 `c0e5065`의 이전 파일 전용 digest 형식이다. 후속 빈 폴더 보호 12개가 이 실행에서 수행됐다고 표시하지 않는다. [원본 보고서·PNG/XML 해시와 추가 대조](windows-transfer-and-rename-verification.json).

## 출시 기준 상태

이전 앱 소스 `5284cb3`의 두 CPU Xcode·전체 UI·프리뷰 설치 작업은 네 작업 모두 성공했다. [최종 결과](5284cb3-ci-verification.json). 한편 `11e948a`의 최적화 성능은 20회 p95 전체 모델 열거 ARM 2.070초·Intel 4.145초로 2초 기준에 미달했다. 첫 표시는 각각 154ms·276ms로 500ms 기준을 통과했다. 원본 표본과 기준을 그대로 보존하고 열거 경로를 후속 분석한다. [성능 원본](optimized-performance-11e948a.json). 정식 서명·공증, 최신 소스 장시간·최소 지원 환경·실제 접근성 수용은 계속 미완료다.
