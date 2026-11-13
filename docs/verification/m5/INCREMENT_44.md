# M5 마흔네 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 선택 위치의 상위 Git 저장소 root 탐지
- `git status --porcelain=v2 --branch -z` 기반 구조화 상태
- 현재 branch·upstream·ahead/behind 추적
- index/worktree 상태, rename 원본, 공백·Unicode·untracked 경로 보존
- 절대 경로·제어문자·손상 record fail-closed
- 읽기 작업에서 terminal prompt와 optional lock 비활성화

## 검증

- 순수 parser의 branch·upstream·ahead/behind·rename·Unicode 검증 통과
- 절대 경로와 손상 record 거부 검증 통과
- 실제 임시 Git 저장소 init/commit/수정/untracked 통합 검증 통과
- 전체 Swift Testing 150개 통과
- FilesMac debug build 통과

## 남은 항목

- branch·remote 목록과 clone/fetch/pull/push 안전 명령
- local bare remote 기반 충돌·예상 ref 변경 검증
- Git AppKit 패널과 파일 목록 상태 열 연결

따라서 M5 Git 영역 완료로 표시하지 않는다.
