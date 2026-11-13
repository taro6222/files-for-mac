# M5 마흔다섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- local branch와 upstream 목록, remote 이름·URL 조회
- 대상 sibling staging 디렉터리에 clone한 뒤 성공 시에만 최종 경로로 publish
- HTTPS·SSH·로컬 file URL만 허용하고 URL 내 credential 거부
- fetch는 prune, pull은 fast-forward-only, push는 force 옵션 없이 실행
- `--force`처럼 옵션으로 해석될 remote/ref 입력 차단
- terminal prompt 비활성화로 비대화형 네트워크 작업 보장

## 검증

- 임시 bare remote와 두 clone으로 clone/fetch/pull/push 왕복 통과
- remote commit 뒤 ahead/behind 판정 및 fast-forward 내용 확인
- 일반 push 뒤 두 번째 clone의 fast-forward 내용 확인
- 옵션형 remote 이름 사전 거부 확인
- 전체 Swift Testing 151개 통과

## 남은 항목

- divergent branch의 `pull --ff-only` 거부와 작업 트리 보존
- 장시간 Git 작업 취소·subprocess 정리
- Git AppKit 패널과 파일 목록 상태 열 연결

따라서 M5 Git 영역 완료로 표시하지 않는다.
