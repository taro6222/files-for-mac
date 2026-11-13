# M6 Increment 19 — 폴더 아이콘 사용자 지정

검증일: 2026-11-14

## 구현

- 폴더 정보 창에서 임의 이미지 파일을 사용자 아이콘으로 설정할 수 있다.
- macOS 공개 API `NSWorkspace.setIcon`을 사용하고 기본 아이콘 복원을 제공한다.
- 파일 또는 다중 선택에서는 폴더 아이콘 조작을 비활성화한다.
- Windows DLL icon index 방식은 복제하지 않고 macOS 네이티브 폴더 아이콘으로 대응한다.

## 검증

- UI QA가 임시 fixture 폴더에 생성 이미지를 적용하고 기본 아이콘을 복원한다.
- `swift test`: 157개 통과.
- `scripts/verify-ui.sh`: 한국어/영어 × 밝게/어둡게 4조합에서 `folderIconCustomization` 통과.
- 화면 감사: macOS 대체 26, 플랫폼 제외 4, 검토 대기 3.

## 남은 화면

- Advanced·General·Tags 설정 화면을 원본의 적용 가능한 목적과 대조한다.
