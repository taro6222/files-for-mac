# M6 Increment 15 — 설정·shell 화면 대응

검증일: 2026-11-14

## 판정

- Actions는 단축키 설정 창, Folders/Layout은 보기 옵션·툴바 설정, Settings 허브는 앱 메뉴의 집중형 macOS utility panel 구조로 대응했다.
- ShellPanes·ColumnShell·ModernShell은 실제 두 pane, 계층형 컬럼, 메인 AppKit 탐색 셸에 연결했다.
- FilesMac은 첫 상호작용 창을 직접 표시하므로 별도 branded splash 화면은 플랫폼 제외로 판정했다.

## 검증

- 기존 UI QA가 단축키 설정, 보기 옵션, 툴바, 양축 분할, pane별 탐색·보기·세션을 4개 언어·테마 조합에서 확인한다.
- `scripts/audit-parity.py`: 화면 33행, macOS 대체 21, 플랫폼 제외 4, 검토 대기 8; 전체 감사 유효.

## 남은 화면

- 속성 사용자 지정·서명, Release Notes, About, Advanced·DevTools·General·Tags 설정을 구현 또는 차이 판정한다.
