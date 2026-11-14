# M6 Increment 68 — macOS 통합 사이드바 설정

검증일: 2026-11-14

## 대응 결정

- Windows의 pinned는 macOS `즐겨찾기` 섹션으로 대응한다.
- library, drives, cloud drives, network는 표준 폴더·장착 볼륨·공개 cloud root를 포함하는 `위치` 섹션으로 통합한다.
- Windows 앱 소유 tag 섹션은 만들지 않고 실제 Finder 태그 기반 검색 명령을 사용한다.
- 세부 섹션별 표시·접힘 토글 대신 두 통합 섹션의 순서·접힘을 저장하고 모든 창에 동기 반영한다.

## 검증

- `sidebarSectionsPersistCollapseAndOrderWithoutChangingHome`에서 통합 섹션 순서, 접힘, 재생성 저장과 홈 설정 비간섭을 검증한다.
- 실제 UI 4개 언어·테마 조합에서 사이드바 위치·접힘·키보드 초점 회귀를 확인한다.
- 패리티 감사에서 10개 설정을 근거가 있는 `platform-alternative`로 분류하고 검토 대기에서 제거한다.
