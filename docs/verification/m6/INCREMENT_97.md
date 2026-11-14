# M6 Increment 97 — Finder 휴지통 연결

- 파일 메뉴와 명령 팔레트의 **Finder에서 휴지통 열기**가 Foundation의 사용자 휴지통 URL을 연다. macOS의 휴지통 비우기는 Finder에서 사용자가 실행한다.
- Finder는 선택 항목 되돌려 놓기를 제공한다. Files for mac의 선택 항목 복원은 대상 폴더를 사용자가 지정하는 별도 기능이다.
- `URL.trashDirectory`는 사용자의 표준 휴지통 디렉터리다. 여러 볼륨과 서비스의 전체 내용이나 항목별 원래 위치 및 삭제 시점을 제공하는 인덱스는 아니다. Windows의 전체 복원, 삭제일·원래 경로 열 및 정렬은 플랫폼 차이로 기록했다.
- 근거: [Foundation 휴지통 디렉터리](https://developer.apple.com/documentation/foundation/url/trashdirectory), [Finder 휴지통 작업](https://support.apple.com/en-ie/guide/mac-help/mchlp1093/27/mac/27), [고정 원본 전체 복원 명령](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/FileSystem/RestoreAllRecycleBinAction.cs).

## 검증

- Swift 테스트 195개와 패리티 감사 통과.
- 한·영 × 라이트·다크 AppKit UI 각 214개 통과. 파일 메뉴의 명령 등록과 사용자 휴지통 URL 전달을 검사했다. 이 자동 검증은 실제 Finder 열기나 항목 변경을 수행하지 않는다.
