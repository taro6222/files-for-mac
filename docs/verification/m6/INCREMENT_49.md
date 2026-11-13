# M6 Increment 49 — macOS 시스템 배경 명령

검증일: 2026-11-14

## 대응

- `SetAsWallpaperBackground`는 이미지로 디코드 가능한 단일 파일에만 활성화하고, 공개 AppKit `NSWorkspace.setDesktopImageURL`로 현재 연결된 각 화면에 적용한다.
- 화면별 기존 표시 옵션을 그대로 전달한다. 어느 화면에서든 실패하면 이미 변경한 화면도 가능한 범위에서 이전 URL과 옵션으로 되돌리고 오류를 표시한다.
- `SetAsLockscreenBackground`와 `SetAsSlideshowBackground`는 macOS 공개 AppKit에 동등한 per-file 명령이 없어 노출하지 않는다. System Settings DB 편집, AppleScript, 비공개 API는 사용하지 않는다.

## 검증 경계

- 주 메뉴·컨텍스트 메뉴·명령 팔레트 등록과 이미지/폴더 활성 조건은 자동 UI 검증에 포함한다.
- 자동 QA는 사용자의 실제 데스크탑 배경을 변경하지 않는다. 실제 명령은 사용자가 메뉴를 명시적으로 실행할 때만 동작한다.
- 앱 내부 사용자 지정 배경(`SetAsAppBackground`)은 별도 기능 단위로 남겨 두며 이번 단위에서 완료 처리하지 않는다.

전체 Swift Testing 170개, 한국어/영어 × 밝게/어둡게 UI 4개 조합, 패리티 감사를 실행한다.
