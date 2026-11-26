# 377 — 원격 UI 준비 빌드 분리

`verify-ui.sh`는 실제 UI 프로세스를 실행하기 전에 SDK 선택 검증용 Release 앱을 만든다. 기존 workflow에서는 이 빌드도 ‘전체 AppKit 시험’의 14분/44분 제한에 포함돼 있었으며 별도 진행 상태와 프로세스 진단이 없었다. UI 단계 진입만으로 실제 창 조작 시작을 확인할 수 없었다.

UI 앞에 ‘Build the archive SDK bundle for AppKit’을 분리했다. 같은 `build-app.sh`로 동일한 서명·SDK 검증을 수행하고 성공한 번들 경로를 `GITHUB_ENV`로 전달한다. `verify-ui.sh`의 기존 override 경로가 준비된 번들을 재사용하므로 UI 단계에서 다시 Release 빌드하지 않는다. 빌드는 기존 관찰/소유 프로세스 회수 도구를 사용하고 진단을 AppKit artifact에 보존한다. 독립 실행 시 기존 자체 준비 경로와 해당 로그도 유지한다.

## 검증과 제한

YAML 파싱, 단계 순서, 준비 명령의 Bash 구문, 기존 CPU별 빌드/UI 제한 유지, 진단 보존 경로를 확인했다. 376 소스 기록과 대조해 제품·시험 소스와 Xcode 프로젝트 hash가 그대로임을 확인했다. 제품 변경이 없어 로컬 빌드·Core·GUI 시험을 반복하지 않았다. 이 구조 검사는 변경한 workflow의 실제 원격 성공을 증명하지 않는다.

기존 [45873718296](https://github.com/taro6222/files-for-mac/actions/runs/45873718296)는 재시작하지 않았다. 관찰 시 두 CPU에서 빌드 진단·Debug 빌드·Swift·SDK 클라이언트·마운트 파일 작업 검사를 통과하고 전체 AppKit 단계가 진행 중이었다. 해당 단계 안에서 번들 빌드와 실제 UI 중 어디까지 도달했는지는 결과와 로그로 확인해야 한다. 이번 수정 전후 어느 실행도 종료 결과 없이 성공으로 집계하지 않는다.

F23/M7 전체 수용은 미완료다. 실제 UI·지원 환경·물리 입력/VoiceOver·정식 서명/공증 등이 남아 있다. [변경 범위·검증 기록](appkit-build-separation-377.json).
