# M6 네 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- ZIP/7z 생성과 압축 탐색·추출 명령 대응
- Git clone/fetch/FF-only pull/push 명령 대응
- 정보·Terminal·확장자·숨김 항목 명령 대응

## 검증

- `scripts/audit-parity.py` 통과
- 명령 202/202, identity 중복 0, 증거 누락 0
- 누적 `implemented` 40개, `awaiting-behavior-review` 162개
- 각 대응에 실제 selector/provider 및 기존 M1/M4/M5 검증 문서 연결

## 보수적 판정

- `GitInit`, `GitSync`는 현재 지원하지 않으므로 대기 유지
- `DecompressArchiveHere*` 변형은 대상 선택형 추출과 의미가 달라 대기 유지
- Windows 관리자 Terminal 및 특정 홈/사이드바 변형은 일반 Terminal 열기로 합치지 않음

따라서 M6 완료로 표시하지 않는다.
