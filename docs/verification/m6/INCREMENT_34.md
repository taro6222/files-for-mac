# M6 Increment 34 — macOS 공유 메뉴 대응

검증일: 2026-11-14

## 구현과 대응

- 원본 Windows `Send To` 메뉴를 macOS의 표준 `NSSharingServicePicker` 공유 흐름으로 대응한다.
- 일반 설정에서 공유 컨텍스트 메뉴 항목의 표시 여부를 변경한다.
- 상세·그리드·목록·컬럼 보기와 모든 열린 창에 즉시 적용한다.
- 설정 영구 저장과 JSON archive 왕복, 이전 archive 기본값 `true`를 지원한다.

## 검증

- 전체 Swift 테스트 165개가 통과했다.
- UI QA가 실제 공유 메뉴 항목의 숨김 상태를 한국어/영어 × 라이트/다크 4개 조합에서 검증했다.
- Finder 확장 목적지 목록을 복제하지 않고 macOS에 설치된 공유 서비스를 런타임에 사용한다.

Windows Send To와 목적지 구성이 동일하다고 주장하지 않으며 `platform-alternative`로 기록한다.
