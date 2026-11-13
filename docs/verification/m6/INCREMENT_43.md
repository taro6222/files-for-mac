# M6 Increment 43 — macOS 전체 화면 전환

검증일: 2026-11-14

## 구현

- 보기 메뉴와 명령 팔레트에 `전체 화면 전환` 명령을 추가했다.
- macOS 표준 `NSWindow.toggleFullScreen`을 사용해 Spaces, 메뉴 막대, traffic light와 시스템 애니메이션 의미를 보존한다.
- macOS 표준 단축키인 Control-Command-F를 연결했으며 사용자 단축키 설정에서도 같은 명령 ID를 사용한다.

## 검증

- Swift 전체 테스트 및 FilesMac 빌드 통과.
- 한국어/영어 × 밝게/어둡게 UI 4개 조합에서 메뉴·명령 팔레트 등록과 패리티 감사가 통과했다.

실제 다중 모니터·다중 Spaces 전환과 전체 화면 복원은 M6 수동 환경 행렬에 남긴다.
