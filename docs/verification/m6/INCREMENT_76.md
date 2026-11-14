# M6 Increment 76 — Git 초기화·안전 동기화

검증일: 2026-11-14

## 구현

- 현재 로컬 폴더에 기존 파일을 변경하지 않고 `git init` metadata를 생성한다.
- 동기화는 현재 branch와 추적 upstream을 검증한 뒤 fetch → fast-forward-only pull → 비강제 push 순서로 실행한다.
- upstream remote가 실제 설정 목록에 없거나 branch/upstream이 없으면 작업 전에 차단한다.
- divergence, 인증 실패 또는 원격 거부 시 force push·reset·자동 merge 없이 실패를 표시한다.
- 실행 중 앱 종료를 차단하고 완료 후 Git 상태 패널과 파일 목록을 갱신한다.

## 자동 검증

- 빈 실제 폴더 초기화와 `.git` 생성, repository snapshot을 검증한다.
- 실제 bare remote와 두 clone에서 원격 변경 pull 및 로컬 commit push 왕복을 검증한다.
- UI 4개 조합에서 두 명령이 메뉴·명령 팔레트에 노출되는지 확인한다.
- 패리티 감사에서 GitInit과 GitSync의 구현 근거를 확인한다.

## 결과

- Swift Testing 180개 통과.
- 한국어·영어 × 밝게·어둡게 4개 실제 AppKit 조합에서 각 190개 검사 통과.
- 패리티 감사 통과: 명령 202/202, 설정 143/143, 화면 33/33.
