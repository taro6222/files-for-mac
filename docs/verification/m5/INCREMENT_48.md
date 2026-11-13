# M5 마흔여덟 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 현재 활성 pane 위치를 대상으로 Git 상태 패널 열기
- 저장소 root, branch, upstream, ahead/behind, index/worktree 상태와 경로 표시
- refresh, fetch, fast-forward-only pull, force 없는 push, 실행 중단 연결
- remote·upstream·branch 유무와 작업 상태에 따른 버튼 활성 조건
- not-repository와 명령 실패를 자동 reset 없이 안내
- 앱 메뉴·명령 팔레트 catalog에 Git 상태 명령 연결

## 검증

- 전체 Swift Testing 153개 통과 및 FilesMac debug build 통과
- 한국어/영어 × 밝게/어둡게 UI 4조합에서 Git 패널 저장소 로드 통과
- 네 조합 모두 Git 메뉴 인덱싱·table/label 접근성 check 통과
- 네 조합 Git 상태 패널 이미지 보관

## 남은 항목

- Git clone UI와 완료 후 탐색 연결
- 로컬 파일 목록 Git 상태 열·지연 갱신
- 인증 HTTPS/SSH remote 및 submodule·LFS·hook 지원 경계 검증

따라서 M5 Git 영역 완료로 표시하지 않는다.
