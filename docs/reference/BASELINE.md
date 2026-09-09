# M0 기준 및 환경

확인일: 2026-09-09

## 고정 원본

- 저장소: https://github.com/files-community/Files
- GitHub latest 안정 릴리스: `v4.2.9`
- 릴리스 게시일: 2026-08-19T20:39:26Z
- 릴리스 메타데이터의 target commit: `99951c66928c4da714da8b1dd46039421182cbab`
- 트리 조회 결과: truncated=false. 소스 참조는 모두 위 SHA에 고정.
- 확인 경로: GitHub releases/latest 및 git/trees API, raw 소스.
- 개발 저장소 초기 이력: `914170356c26db0b5bc91e97f8321ea19519de8b` (LICENSE). 기존 이력 위에서 작업.

## 확인된 도구

- Xcode 26.6, build 17F113
- Apple Swift 6.3.3, swiftlang-6.3.3.1.3
- macOS 26.6.2, build 25G83
- 실행 CPU: arm64
- deployment target: macOS 14.0. 최소 OS 실기기와 Intel 실행은 아직 미검증.

## 인벤토리의 정확한 범위

`scripts/inventory-upstream.py`로 재현할 수 있다. 183개 Actions/Settings 소스에서 GeneratedRichCommand attribute가 있는 명령 후보 202개, 단순 Get 기반 설정 프로퍼티 143개를 추출했다. `SCREENS.csv`는 Views 하위 XAML 파일 33개다.

명령 generator는 attribute가 붙은 class 이름에서 Action 접미사를 제거하여 명령 ID를 만든다. Actions 디렉터리 밖의 등록, 다른 generator가 추가하는 파라미터별 명령, 복합 설정, dialog/control 내부 화면은 추가 조사 대상이다. 파일 수를 개별 기능 전수 조사 완료 수치로 쓰지 않는다.

- COMMANDS.csv: 개별 attribute 명령 후보; 현재 기본 상태 V/awaiting-behavior-review.
- SETTINGS.csv: 단순 getter의 key/type/default expression; 동작 및 의존 설정 검증 대기.
- SCREENS.csv: 화면 소스 파일 목록; 실제 상태 캡처 대기.
- SOURCE_FILES.csv: 추출에 사용한 파일 경로 목록.

새로 발견한 범위: Shelf pane 관련 명령 4개가 기준 소스에 존재한다. 초기 기능군에 F41을 추가하고 상세 동작을 조사한다.

## 완료하지 않은 M0 게이트

Windows 실행 환경에서 모든 화면·상태 캡처, 원본 명령·설정의 최종 전수 대조, 휴지통 전체 복원/클라우드/압축 backend/Intel 실행 실험은 미완료다. 따라서 M0 전체를 완료로 표시하지 않는다. 설계서의 독립 개발 허용에 따라 M1 로컬 탐색을 먼저 구현한다.
