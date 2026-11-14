# Files for Mac

Files의 탐색 경험을 macOS용 네이티브 앱으로 구현하는 프로젝트입니다.

- 개발 저장소: https://github.com/taro6222/files-for-mac
- 비교 원본: files-community/Files `v4.2.9` (`99951c66928c4da714da8b1dd46039421182cbab`)
- 현재 상태: **M7 로컬 배포 검증 진행 중**. 자세한 구현 범위와 검증 현황은 개발 현황 문서에서 확인할 수 있습니다.

## 실행

최소 배포 대상은 macOS 14입니다. 최신 프리뷰는 Apple Silicon macOS 27.2에서 검증했습니다. Intel과 macOS 14 실행 검증은 진행 중입니다.

```sh
./scripts/build-app.sh
open 'build/Files macOS.app'
```

Apple Silicon·Intel 유니버설 로컬 프리뷰 설치 이미지와 SHA-256 파일은 `./scripts/build-dmg.sh --preview`로 생성합니다.

[0.1.0 설치 안내 및 지원 범위](docs/RELEASE_NOTES.md)

또는 `FilesMac.xcodeproj`를 Xcode에서 열고 `Files macOS` scheme을 실행합니다. SwiftPM에서는 `Package.swift`로 코어 테스트와 앱을 빌드합니다.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox
```

빌드 스크립트의 `--disable-sandbox`는 SwiftPM 빌드 프로세스에만 적용합니다. 앱의 TCC 또는 시스템 권한을 해제하지 않습니다. 생성 앱은 로컬 개발용 ad-hoc 서명이며 정식 배포용 서명·공증 앱이 아닙니다.

## 현재 구현

홈 드라이브 용량 카드, 실제 폴더 상세 목록, 폴더 열기, 경로 입력·추천·Tab 완성, 뒤로/앞으로/상위 이동, 다중 선택, 열 정렬·순서·크기 저장, 숨김 항목·확장자 전환, 여러 창에 공유되는 즐겨찾기 추가/제거/순서, 최근 위치 삭제, 사이드바 섹션 접기·순서 저장, 시스템 앱으로 파일 열기, Finder에서 보기, FSEvents 자동 갱신·외부 이름 변경 후 선택 유지를 제공합니다. 대용량 폴더는 첫 128개부터 배치로 표시합니다.

파일 생성·복사·이동·이름 변경, 탭·분할 pane, 상세·그리드·목록·컬럼, 검색, ZIP/7z 생성 및 RAR 탐색·추출, 원격 연결과 Git 기본 작업도 제공합니다.

## 문서

- [설계 문서](docs/README.md)
- [개발 현황과 다음 작업](docs/DEVELOPMENT_STATUS.md)
- [원본 기준 및 환경](docs/reference/BASELINE.md)
- [M1 검증 기록](docs/verification/m1/REPORT.md)

원본 코드를 앱 구현에 복사하지 않았습니다. 비교 인벤토리는 고정 소스의 식별자·경로·설정 메타데이터를 참조합니다. 원본의 브랜드 자산을 포함하지 않습니다.

폴더 감시 통합 테스트는 macOS FSEvents 서비스 접근이 필요합니다. 제한된 실행 샌드박스에서는 서비스 접근이 차단되어 실패할 수 있으므로 실제 macOS 개발 환경에서도 실행합니다.

키보드: ⌃⌘S로 사이드바, ⇧⌘L로 파일 목록, ⇧⌘H로 홈, ⌘,로 보기 옵션에 접근합니다. 사이드바에서는 ↑/↓로 이동하고 Space로 실행하며 Shift+F10으로 항목 메뉴를 엽니다. 폴더를 읽는 중에는 Esc 또는 도구 모음의 읽기 중단 버튼으로 멈추고, ⌘R로 다시 읽을 수 있습니다. 중단된 목록은 불완전할 수 있습니다.

### UI 검증

로그인된 macOS GUI 세션에서 `scripts/verify-ui.sh`를 실행하면 최소 창 크기의 한국어/영어 및 두 테마, 오류 안내, 다중 창 반복 탐색을 독립 테스트 설정으로 검증한다. 결과·이미지는 `build/ui-verification/`에 저장된다. `--performance`를 붙이면 20회 반복·100개 스크롤 위치의 표본과 p95를 `build/ui-performance/`에 저장한다. [최신 검증 범위와 한계](docs/verification/m1/INCREMENT_09.md)를 참고한다.

자동 갱신은 연결 중과 사용 불가 상태를 구분합니다. 폴더를 다시 선택하거나 이동 메뉴의 `자동 갱신 다시 연결`로 등록을 재시도할 수 있습니다.
