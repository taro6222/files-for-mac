# M6 Increment 95 — 시스템 저장 공간 설정

- 이동 메뉴와 파일 보기의 컨텍스트 메뉴는 선택이 없는 로컬 볼륨 루트에서 저장 공간 설정을 연다. 홈과 사이드바의 로컬 드라이브 메뉴에서도 실행할 수 있다. 네트워크 볼륨은 대상에서 제외한다.
- 세 진입점은 macOS 시스템 설정의 일반 → 저장 공간으로 연결한다. 이 화면은 Mac의 저장 공간을 관리하며 클릭한 볼륨을 개별 선택하지 않는다. 앱은 저장 공간 설정이나 파일을 변경하지 않는다.
- 시스템이 URL 열기를 거절하면 일반 → 저장 공간을 직접 여는 경로를 안내한다.
- [Apple 저장 공간 설정 안내](https://support.apple.com/guide/mac-help/change-storage-settings-mchl3d437fbc/mac)와 [고정 원본 저장 공간 명령](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Open/OpenStorageSenseAction.cs)을 기준으로 대응했다.

## 검증

- Swift 테스트 193개와 패리티 감사 통과.
- 한국어·영어 × 밝게·어둡게 AppKit UI 각 212개 통과. 현재 볼륨의 명령, 홈과 사이드바 메뉴의 URL 전달, 네트워크 볼륨 제한을 확인했다.
- 동일 URL을 열고 시스템 설정의 접근성 트리에서 일반 → 저장 공간 화면이 표시되는 것을 확인했다.
