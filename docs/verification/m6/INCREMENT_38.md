# M6 Increment 38 — Windows 셸 확장 메뉴 경계

검증일: 2026-11-14

## 판정

- 원본 `MoveShellExtensionsToSubMenu`는 Explorer가 주입한 Windows shell extension verb의 메뉴 계층을 바꾼다.
- FilesMac 컨텍스트 메뉴는 AppKit 앱이 직접 소유하며 Explorer shell extension verb를 가져오지 않는다.
- 공유 목적지는 macOS `NSSharingServicePicker`가 설치 상태에 따라 제공하므로 Windows 셸 확장 하위 메뉴를 복제하지 않는다.
- 따라서 이름만 같은 무동작 설정을 추가하지 않고 `platform-excluded`로 기록한다.

## 검증

- 패리티 감사가 근거 링크와 함께 해당 설정을 제외 항목으로 집계한다.
- 앱 명령 팔레트·컨텍스트 메뉴와 네이티브 공유 메뉴는 기존 UI 4개 조합에서 검증됐다.

나머지 미판정 설정과 명령은 계속 검토 대기로 유지한다.
