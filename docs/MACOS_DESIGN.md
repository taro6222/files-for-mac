# Files macOS 제품·UI·기술 설계

작성일: 2026-09-09 · 버전: 1.0 · 상태: 개발 기준 설계

## 1. 목표와 완성의 정의

Files의 정보 구조, 탐색 경험, 화면 밀도, 사용자 지정, 고급 파일 관리를 macOS에 구현한다. 별도 앱으로 실행되며 실제 파일을 다룬다. 화면 모형, 임시 데이터, 동작하지 않는 메뉴로 기능을 대신하지 않는다.

완성은 다음 네 가지를 모두 만족하는 상태다.

1. 고정한 원본 버전의 모든 기능·명령·설정에 구현 또는 명시적인 macOS 대응이 존재한다.
2. 모든 주요 화면과 정상·로딩·빈 결과·오류·비활성·선택·드래그 상태에 검증 증거가 있다.
3. 파일 내용과 메타데이터의 무결성, 오류 복구, 대용량 성능, 접근성이 출시 기준을 통과한다.
4. 서명된 설치 산출물로 깨끗한 Mac에서 설치·실행·업데이트·복구를 확인한다.

Windows 운영체제 동작 자체를 macOS에 복제하는 것은 범위상 구분한다. 예를 들어 레지스트리, COM 셸 확장, NTFS alternate data stream은 macOS의 동일 기능으로 간주하지 않는다. 차이를 기록하고 가능한 사용자 목적을 대응 구현한다.

## 2. 조사 근거와 기준 버전

원본 앱 프로젝트에는 WinUI, Windows 런타임 대상, Windows App SDK, COM 및 Win32 DLL 의존성이 명시되어 있다. UI와 운영체제 통합을 macOS용으로 재작성하는 구조로 결정한다. [원본 프로젝트 설정](https://github.com/files-community/Files/blob/main/src/Files.App/Files.App.csproj)

현재 조사 대상은 2026-09-09에 열람한 `main`의 프로젝트 설정과 공식 문서다. 저장소 전체 코드와 Windows 실행 화면을 전수 검증한 상태는 아니다. 개발 기준 SHA·릴리스 번호는 M0에서 실제 조회하여 기록해야 하며 추정 값을 쓰지 않는다. 공식 문서와 원본 실행 결과가 다르면 고정한 소스와 실행 결과를 우선하고 차이를 이력에 남긴다.

원본 공식 기능 안내에는 탭, 여러 레이아웃, 미리보기, 테마, 압축, Git 등이 제시된다. 이 설계의 상세 동작과 성능 수치는 그 소개 문구를 그대로 옮긴 것이 아니라 맥 앱을 위한 개발 요구사항이다. [공식 기능 소개](https://files.community/)

## 3. 기술 및 지원 정책

| 항목 | 설계 결정 | 이유 또는 검증 조건 |
|---|---|---|
| 언어 | Swift, 도구 버전은 M0에서 설치 환경과 함께 고정 | 동시성 검사와 Apple API 통합 |
| UI | AppKit 창·목록·그리드 + SwiftUI 설정·패널 | 대규모 목록, 키보드·드래그 제어, 선언형 화면 조합 |
| 최소 OS | macOS 14 이상을 초기 목표로 설정 | 실제 API availability와 Intel 지원은 M0 빌드로 확정 |
| CPU | Apple Silicon, Intel을 목표로 각각 검증 | 한 아키텍처 실행으로 다른 쪽 지원을 단정하지 않음 |
| 패키징 | Xcode 앱 타깃 + 내부 Swift Package 모듈 | 앱 서명과 모듈 테스트 분리 |
| 저장 | SQLite 메타데이터/작업 저널, UserDefaults 간단 설정, Keychain 비밀 | 역할별 분리 및 버전 마이그레이션 |
| 배포 | Developer ID 서명·공증한 DMG 직접 배포 | 초기 배포 기준; App Store는 별도 적합성 검토 |
| 권한 | 직접 배포 버전은 App Sandbox 미사용 설계를 우선 검증 | TCC·파일 권한·SIP는 계속 적용; 자동 우회 없음 |
| 네트워크 | 서비스별 provider, 자격 증명은 Keychain | 로컬 탐색에 네트워크 연결을 필수로 요구하지 않음 |
| 기본 언어 | 한국어·영어 | UI 문자열·복수형·날짜·단위·접근성 설명 분리 |

SwiftUI와 AppKit 혼용은 Apple이 지원하는 구성이다. UI 플랫폼 선택의 근거로 사용한다. [SwiftUI](https://developer.apple.com/swiftui/)

소스·아이콘·번역·브랜드 자산을 재사용할 때는 M0에서 파일별 라이선스와 출처를 기록한다. 저장소의 MIT/MPL 표기만으로 모든 자산을 동일 조건으로 취급하지 않는다. 배포명은 임시로 `Files macOS`를 사용하며 공식 프로젝트라는 인상을 주는 명칭·로고의 최종 사용 여부는 출시 준비에서 확정한다.

## 4. UI 정보 구조

### 4.1 기본 창

```text
┌──────────────────────────────────────────────────────────────────┐
│ ● ● ●   [탭 1 ×] [탭 2 ×] [+]                         탭 목록    │
├───────────────┬──────────────────────────────────────────────────┤
│ 홈            │ ← → ↑ 새로고침  [경로 / 검색 / 명령]              │
│ 즐겨찾기      ├──────────────────────────────────────────────────┤
│  다운로드     │ 새 항목  복사  붙여넣기  정렬  보기  …            │
│  문서         ├─────────────────────────────┬────────────────────┤
│ 위치          │ 이름      수정일   종류   크기│ 정보 / 미리보기    │
│  내부 디스크  │ 폴더와 파일 목록             │ 아이콘·썸네일      │
│  외장 디스크  │                             │ 속성·태그·해시     │
│ 클라우드      │                             │                    │
│ 네트워크      ├─────────────────────────────┴────────────────────┤
│ 태그          │ 항목 수 · 선택 크기 · Git 상태 · 작업 진행       │
└───────────────┴──────────────────────────────────────────────────┘
```

원본의 탭·사이드바·경로·명령·파일 영역·정보 패널 계층을 유지한다. 창 제어는 macOS traffic lights를 사용한다. 그림은 설계 와이어프레임이며 원본을 측정한 픽셀 명세가 아니다.

### 4.2 치수와 스타일

다음은 M0 시각 대조 이전의 초기 토큰이다. 원본 측정값과 차이는 `reference/UI_BASELINE.md`에 기록하고 확정한다. 단위는 macOS point다.

| 토큰 | 초기값 | 제약 |
|---|---:|---|
| 기본 창 | 1280 × 820 | 화면 경계를 넘지 않도록 복원 |
| 최소 창 | 900 × 600 | 축소 시 툴바 overflow; 텍스트 겹침 금지 |
| 탭 영역 | 40 | 탭 너비 120~240, 넘침 목록 제공 |
| 경로 영역 / 명령 영역 | 44 / 40 | 입력창·메뉴 포커스와 클릭 영역 보존 |
| 사이드바 | 220 | 180~320 드래그 조절 |
| 상세 행 | 32 | 조밀 28, 편안 40 |
| 정보 패널 | 280 | 240~420, 좁은 창에서는 명시적으로 접기 |
| 상태 표시줄 | 26 | 긴 상태는 줄임표와 툴팁 |
| 간격 | 4, 8, 12, 16, 24 | 컴포넌트에서 상수 직접 작성 금지 |
| 모서리 | 6, 8, 12 | 팝오버·카드·선택 영역 역할별 적용 |
| 기본 글꼴 | 시스템 폰트 13 | 제목 18/22, 메타데이터 11/12; 사용자 변경 지원 |

색은 background/sidebar/surface/elevated/textPrimary/textSecondary/border/accent/selection/error 토큰으로 분리한다. 밝게·어둡게·시스템 연동을 지원한다. 활성 선택과 비활성 창 선택을 구분한다. Mica/Acrylic의 목적은 macOS material로 대응하고 모양의 차이는 UI 기준에 남긴다. 투명도 감소와 대비 증가 설정에서는 불투명 대체를 적용한다.

원본 외형 설정은 테마, 재질, 글꼴, 배경 이미지 등의 사용자 지정을 제공한다. 맥 설계에서도 이를 독립 설정으로 다룬다. [Appearance](https://files.community/docs/customize-settings/appearance)

### 4.3 화면 목록과 상세 동작

| ID | 화면 | 필수 동작과 상태 |
|---|---|---|
| UI-01 | 홈 | 즐겨찾기·드라이브·최근 항목; 섹션 표시 설정; 최근 항목 비우기; 접근 불가 위치 구분 |
| UI-02 | 기본 탐색 | 경로 이동·히스토리·파일 목록·선택·상태; 뒤로 이동 시 스크롤과 선택 복원 |
| UI-03 | 상세 보기 | 열 너비·순서·표시 저장; 이름·종류·크기·날짜·태그; 추가 열은 capability에 따라 제공 |
| UI-04 | 목록·카드·그리드 | 동일 선택 모델; 아이콘 크기 조절; 카드의 추가 메타데이터; 가상화 |
| UI-05 | 컬럼 보기 | 계층별 열; 키보드 좌우 이동; 경로 변경과 선택 연동; 수평 스크롤 |
| UI-06 | 분할 보기 | 좌우·상하 두 pane; 독립 경로·히스토리·레이아웃; 활성 pane 표시; 사이 비율 저장 |
| UI-07 | 검색 | 현재 폴더/하위 포함/검색 가능한 전체 위치 구분; 진행·취소·부분 결과·미인덱싱 표시 |
| UI-08 | 정보·미리보기 | 단일·다중 선택; 기본 속성·태그·Git; 비지원 포맷·로딩·실패 상태 |
| UI-09 | 속성 창 | 경로·크기·날짜·권한·메타데이터·해시; 편집 가능한 필드만 입력 가능 |
| UI-10 | 작업 센터 | 전체/개별 진행·속도·남은 양·취소·결과·실패 재시도; 불명확한 ETA는 숨김 |
| UI-11 | 충돌 대화상자 | 양쪽 경로·유형·크기·날짜·미리보기; 건너뛰기/양쪽 유지/교체; 폴더 병합 별도 |
| UI-12 | 일괄 이름 변경 | 패턴·번호·찾기/바꾸기·정규식·미리보기; 중복과 유효하지 않은 이름 표시 |
| UI-13 | 압축 탐색·생성 | 압축 내부 경로·목록·추출·생성 옵션·암호; 수정 지원 포맷만 편집 노출 |
| UI-14 | 연결 관리자 | 서버·프로토콜·포트·인증·즐겨찾기; 신뢰 확인·연결 실패·오프라인 |
| UI-15 | Git 패널 | 브랜치·변경 상태·원격 작업·진행·충돌; 작업 트리 변경 전 영향 표시 |
| UI-16 | 명령 팔레트 | 문자열 검색·현재 문맥·단축키 표시; 실행 불가 이유; 완전한 키보드 조작 |
| UI-17 | 설정 | 일반/외형/파일·폴더/레이아웃/태그/명령/연결/개발 도구/고급/정보 |
| UI-18 | 휴지통 | 시스템 휴지통 열기 + 앱이 이동한 항목 복원 기록; 전체 목록·복원은 M0 API 검증 게이트 |
| UI-19 | 사용자 지정 | 툴바 버튼 순서·표시, 사이드바 순서, 테마·배경, 폴더별 설정 |
| UI-20 | 최초 실행·접근 오류 | 위치 선택·접근 허용 안내·다시 시도; 권한 실패를 빈 폴더로 표시하지 않음 |

### 4.4 상호작용 계약

- 단일 클릭은 선택, 이중 클릭/⌘↓는 열기, Return은 이름 변경, Space는 Quick Look이다. 텍스트 입력 중 단축키는 편집기가 우선한다.
- ⌘클릭 토글, Shift 범위 선택, 드래그 박스 선택, 전체/반전/선택 해제를 제공한다. 정렬 후에도 항목 ID로 선택을 유지한다.
- 빈 공간·파일·폴더·다중 선택·드라이브·압축 내부·Git 저장소의 문맥 메뉴를 각각 정의한다. 메뉴·팔레트·툴바는 같은 CommandRegistry를 사용한다.
- 탭 생성·복제·순서 변경·닫기·다시 열기·다른 창으로 이동을 제공한다. 닫은 탭 복원은 위치뿐 아니라 분할 상태와 보기 설정을 포함한다.
- 분할은 활성 pane에 명령을 전달한다. 반대 pane 이동 명령은 대상을 실행 전에 표시한다. 탭 드래그로 좌우·상하 분할을 만드는 동작을 포함한다. 원본 분할의 두 방향과 탭 드롭 동작은 공식 안내로 확인했다. [Dual pane](https://files.community/docs/features/dual-pane)
- 주소 입력은 경로 자동 완성과 방문 기록을 제공한다. 경로·검색·명령 모드는 표시로 구분하고 문자열을 임의의 셸 명령으로 실행하지 않는다.
- 드래그 시 복사/이동/링크 의미와 목적지를 표시한다. 외부 앱·Finder와 파일 URL 및 file promise 교환을 지원한다. modifier별 결과는 Finder 관례와 실제 통합 테스트로 확정한다.
- 이름 편집은 확장자 제외 기본 선택, Esc 취소, 확장자 변경 확인, 대소문자만 변경 처리, IME 조합 중 확정 방지를 포함한다.
- 메뉴·팝오버를 닫으면 원래 포커스로 돌아간다. 모달은 키보드와 VoiceOver에서 밖으로 포커스가 새지 않는다.

초기 단축키: 새 탭 ⌘T, 새 창 ⌘N, 탭 닫기 ⌘W, 닫은 탭 복원 ⇧⌘T, 경로 ⌘L, 검색 ⌘F, 설정 ⌘,, 복사 ⌘C, 붙여넣기 ⌘V, 이동 붙여넣기 ⌥⌘V, 실행 취소 ⌘Z, 다시 실행 ⇧⌘Z, 휴지통 ⌘Delete, 숨김 표시 ⇧⌘., 새 폴더 ⇧⌘N, 팔레트 ⇧⌘P. 원본 Windows 키를 일괄 치환하지 않고 macOS 예약 키와 충돌 검사를 수행한다.

### 4.5 레이아웃 정책

상세·목록·카드·그리드·컬럼을 별도 구현하고 폴더별 설정을 저장한다. 적응형 보기와 전체 폴더에 보기 설정 동기화의 상호 배타 정책은 원본 동작에 맞춰 검증한다. [Layout picker](https://files.community/docs/features/layout-picker)

적응형 분류의 초기 설계는 이미지·영상 등 종류 비율을 이용하되 현재 사용자 선택을 덮어쓰지 않는다. 분류 기준과 샘플링 개수는 측정 후 확정한다. 목록 로딩 중 레이아웃을 계속 전환하지 않는다.

## 5. 모듈 구조

```text
FilesMac/
  App/                  창 수명·메뉴·의존성 조립·권한 안내
  Packages/
    Domain/             ID·엔티티·명령·provider 계약
    Navigation/         창/탭/pane 상태·히스토리
    BrowserUI/          목록·그리드·컬럼·사이드바
    Operations/         계획·저널·실행·충돌·취소·복구
    LocalFileSystem/     열거·관찰·메타데이터·로컬 I/O
    Search/             Spotlight·범위 탐색·필터
    Preview/            Quick Look·썸네일 캐시
    Integrations/       Archive·Remote·Cloud·Git·System
    Persistence/        SQLite·설정·마이그레이션
    DesignSystem/       토큰·공통 상태·접근성
  Tests/                단위·통합·UI·성능·장애 주입
  Resources/            문자열·테마·사용 허가된 자산
  docs/
```

의존 방향은 `App/UI → Application services → Domain contracts ← Providers`다. Domain에는 AppKit 타입을 넣지 않는다. UI가 파일 삭제나 네트워크 호출을 직접 실행하지 않는다. 파일 I/O와 Git·압축은 main thread 밖에서 실행한다. 목록 결과는 generation ID를 확인해 오래된 탐색 결과가 새 경로를 덮지 못하게 한다.

### 5.1 주요 모델

| 모델 | 필수 필드 |
|---|---|
| FileItem | providerID, itemID, URL/locator, parentID, displayName, kind, byteSize?, timestamps?, capabilities, metadataState |
| Location | local/remote/archive/search/home/tag, providerID, locator, accessReference? |
| PaneState | paneID, location, back/forward, selectionIDs, focusedID, scrollAnchor, layout, sort, grouping, query |
| TabState | tabID, title, panes[1..2], splitAxis, ratio, activePaneID |
| WindowState | windowID, tabs, activeTabID, frame, sidebarWidth, infoPaneState |
| FileOperation | operationID, intent, sourceRefs, destinationRef, policy, state, progress, itemResults |
| JournalEntry | operationID, stepID, originalRef, stagedRef, finalRef, identitySnapshot, reversibleAction?, committedAt? |
| Command | stableID, localizedLabel, category, shortcut, canExecute(context), execute(context) |
| ProviderCapabilities | enumerate/read/write/move/trash/restore/watch/metadata/thumbnail/search/resume/atomicReplace |

로컬 항목은 볼륨 식별자와 파일 식별 정보를 우선 사용하고 경로를 보조로 저장한다. inode 재사용과 파일 변경 가능성을 고려해 복구 시 재검증한다. 원격 provider는 자체 안정 ID 또는 locator+재검증 토큰을 사용한다. 이름의 Unicode 정규화는 표시·검색과 실제 파일 식별을 분리한다.

### 5.2 Provider 계약

```swift
protocol FileSystemProvider: Sendable {
    func capabilities(at: Location) async throws -> Capabilities
    func enumerate(_ location: Location, options: ListingOptions)
        -> AsyncThrowingStream<ListingBatch, Error>
    func metadata(for: ItemReference) async throws -> ItemMetadata
    func events(at: Location) -> AsyncThrowingStream<ChangeBatch, Error>
    func validate(_ plan: OperationPlan) async throws -> ValidationResult
    func execute(_ step: OperationStep) -> AsyncThrowingStream<OperationEvent, Error>
}
```

이는 구현 계약의 의사 코드다. observer를 제공하지 않는 provider는 polling과 수동 새로고침으로 대체한다. capability 없는 동작은 성공으로 흉내 내지 않는다. 인스턴스 수명, 취소 전달, 오류 타입을 구현 시 명시한다.

### 5.3 상태 저장

SQLite 테이블: schema_versions, favorites, location_preferences, window_sessions, recent_locations, operation_jobs, operation_steps, undo_records, connection_profiles. 인증 정보는 connection_profiles에 저장하지 않고 Keychain reference만 둔다.

설정 우선순위: 세션의 명시 선택 → 폴더별 설정 → 전역 기본값. 스키마 변경은 트랜잭션과 마이그레이션 테스트를 동반한다. 세션 저장은 debounce와 원자적 교체를 적용한다. 손상 시 백업 복원 또는 안전한 기본 상태로 시작하되 파일 데이터에는 손대지 않는다.

## 6. 파일 작업 엔진

### 6.1 공통 파이프라인

`요청 → 소스/대상 검증 → 계획 생성 → 저널 기록 → 임시 출력 → 결과 검증 → 커밋 → UI 통지 → 실행 취소 기록`

상태는 queued, planning, running, awaitingConflict, cancelling, completed, partiallyCompleted, cancelled, failed, interrupted로 구분한다. pause/resume은 실제 지원 provider와 작업에만 제공한다. 앱 재시작 후 byte 단위 재개를 보장하지 않으며 미완료 작업은 우선 interrupted로 복원한다.

- 소스와 대상이 같은 항목인지, 자기 하위로 폴더 이동인지, 쓰기 권한·볼륨 상태·이름 충돌·가능한 여유 공간을 검사한다.
- 경로의 문자열 검사만 믿지 않고 심볼릭 링크와 최종 대상 identity를 검증한다. 실행 시점에도 재확인한다.
- 동일 볼륨 이동은 rename을 우선하되 원자성은 해당 파일 시스템에서 확인한다. 다른 볼륨 이동은 복사·검증·대상 확정 후 소스를 제거한다.
- 복사 대상은 같은 대상 디렉터리의 고유 임시 이름으로 작성한다. 내용과 메타데이터를 검증한 뒤 최종 이름으로 확정한다. 기존 파일 교체는 복구 가능한 백업 절차를 둔다.
- 다수 파일 작업은 전체 원자성을 보장하지 않는다. 항목별 성공·실패·미실행을 표시하고 실패 항목만 재시도한다.
- source 변경을 발견하면 충돌로 전환한다. 사용자가 선택한 교체 정책도 새로운 외부 변경에는 재검증한다.
- 해시는 큰 파일에서 비용이 있으므로 일반 복사 검증 수준과 강한 검증 옵션을 구분한다. 이동 시 검증 정책이 만족되기 전에 소스를 지우지 않는다.

### 6.2 충돌과 취소

파일/파일, 폴더/폴더, 파일/폴더 충돌을 구분한다. 폴더 병합은 재귀 항목 단위 계획을 만들며 '병합'과 '폴더 교체'를 같은 동작으로 처리하지 않는다. '모두 적용'은 현재 작업·현재 충돌 종류에만 적용한다. '양쪽 유지' 이름은 실제 생성 성공을 기준으로 경쟁 조건을 처리한다.

취소는 새 항목 시작을 중단하고 현재 출력의 안전한 중단 지점을 기다린다. 이미 완료된 항목을 자동으로 되돌리지 않는다. 임시 파일은 저널 소유권을 확인한 것만 정리한다. 작업 중 앱 종료는 대기/취소 후 종료 선택을 제공하고 강제 종료 복구를 별도로 시험한다.

### 6.3 실행 취소와 휴지통

실행 취소 전 대상 identity·내용 변경 여부를 검증한다. 복사 취소는 앱이 만든 결과만 제거하고, 이동 취소는 원래 위치 충돌을 처리한다. 교체 취소에는 백업이 필요하다. 외부 변경으로 되돌릴 수 없으면 이유를 표시한다. 영구 삭제는 복구 가능하다고 표시하지 않는다.

기본 삭제는 시스템 휴지통 이동이다. 앱이 이동한 파일은 반환된 휴지통 URL과 원래 위치를 기록한다. 시스템 전체 휴지통의 원래 위치 정보와 '모두 복원'을 공개 API만으로 어디까지 제공할 수 있는지는 M0 실험으로 확정한다. 비공개 DB나 Finder 내부 형식에 의존하는 구현은 기본안으로 채택하지 않는다. 그 결과 완전한 대응이 불가능하면 해당 항목을 미해결 플랫폼 차이로 남긴다.

### 6.4 보존할 파일 특성

내용, 권한, 실행 비트, 시간 정보, 확장 속성, Finder 태그, resource fork, 심볼릭 링크 자체, package 디렉터리, 가능한 경우 hard link 관계와 sparse 특성을 검증한다. 대상 파일 시스템이 지원하지 않는 속성은 성공 메시지에 숨기지 않고 손실 가능성을 표시한다. APFS·대소문자 구분 APFS·exFAT·SMB를 서로 다른 시험 대상으로 둔다.

파일 관리 기본 API 후보는 Foundation FileManager다. 실제 복사 정책과 진행·취소는 별도 엔진에서 검증한다. [FileManager](https://developer.apple.com/documentation/foundation/filemanager)

## 7. 통합 기능 설계

### 검색

Spotlight adapter와 직접 열거 adapter를 분리한다. 인덱싱되지 않은 위치는 파일명 검색으로 이어갈 수 있지만 전체 콘텐츠 검색과 동일하다고 표시하지 않는다. 결과는 배치로 전달하고 중복 identity를 제거한다. query generation 변경 시 이전 결과를 폐기한다. 이름·유형·크기·날짜·태그 필터를 조합하고 날짜 경계는 로컬 시간대를 명시한다.

### 미리보기와 썸네일

Quick Look/Quick Look Thumbnailing을 이용하는 adapter를 둔다. cache key에는 항목 identity·수정 정보·요청 크기를 포함한다. 보이는 항목 우선으로 생성하며 취소와 메모리 압박 시 해제를 지원한다. 암호 파일·미지원 파일은 일반 아이콘과 오류를 표시한다. 클라우드 항목의 자동 다운로드는 별도 정책으로 제어한다.

### 드라이브·네트워크·클라우드

마운트/해제 이벤트로 사이드바를 갱신한다. 작업 중 eject 요청은 실행 중 작업을 설명한다. SMB는 macOS 마운트 경로를 기본 경로로 사용한다. FTP/FTPS와 SFTP는 별도 프로토콜 provider로 구현하고 연결·목록·전송·취소·재시도·인증을 공통 UI에 연결한다. SFTP는 추가 맥 요구사항이며 원본 지원으로 단정하지 않는다.

설치된 클라우드 클라이언트가 노출한 로컬 위치를 탐색한다. 전용 동기화 엔진을 중복 개발하지 않는다. 상태·다운로드·오프라인 유지·공간 비우기는 provider별 공개 API로 검증된 capability만 제공한다. 알 수 없는 상태를 '동기화 완료'로 바꾸지 않는다.

### 압축

ArchiveProvider는 browse/extract/create/update/password capabilities를 포맷별로 갖는다. 초기 엔진 후보는 libarchive와 별도 7z backend이며 버전·배포 조건·지원 조합은 M0에서 확정한다. ZIP·7z 생성/읽기/추출과 RAR 읽기/추출을 목표로 한다. RAR 생성은 기본 엔진에서 보장하지 않으며 별도 지원 여부를 기록한다. 암호·분할 압축·손상 복구는 실제 fixture 통과 전 지원으로 표시하지 않는다.

추출은 절대 경로, `..`, 링크를 통한 대상 이탈을 차단한다. 압축 폭탄 방지를 위해 파일 수·총 해제 크기·공간 한도를 사전/실행 중 검사한다. 압축 내부 수정은 지원 포맷에서 새 임시 아카이브를 만들어 교체한다. 사용자의 원본 아카이브를 스트리밍 중 직접 훼손하지 않는다.

### Git

상태·브랜치·추적 상태·커밋 메타데이터·init/clone/fetch/pull/push/sync를 제공한다. 실제 backend는 libgit2 또는 인자 배열 기반 Git 프로세스 후보를 M0에서 비교한다. 저장소 hooks·인증·submodule·LFS 지원 경계를 문서화한다. 네트워크 작업과 브랜치 변경은 사용자가 실행한 명령에만 반응한다. 충돌을 자동 reset/clean으로 해결하지 않는다.

공식 Git 설명과 명령 목록은 Sync 설명이 서로 다를 수 있으므로, 상태 새로고침과 pull+push 명령을 구분하고 고정한 소스 구현을 대조한다. [Git 문서](https://files.community/docs/features/git), [명령 목록](https://files.community/docs/features/command-palette)

### 시스템 연동

NSWorkspace 기반 열기·연결 프로그램·Finder 위치 표시, 공유 메뉴, 기본 터미널/IDE 열기를 제공한다. 외부 프로세스 인자는 배열로 전달하고 파일명을 셸 코드로 결합하지 않는다. 파일 약속 기반 드래그의 API 후보는 NSFilePromiseProvider다. [Apple 문서](https://developer.apple.com/documentation/appkit/nsfilepromiseprovider)

## 8. 개인정보와 운영

파일명·전체 경로·서버 주소·인증 정보를 기본 로그에 남기지 않는다. 오류 로그는 작업 ID와 오류 코드 중심으로 남긴다. 상세 진단 내보내기는 미리보기와 민감정보 제거를 제공한다. 텔레메트리는 기본 비활성이다.

최근 위치와 캐시는 사용자가 삭제할 수 있다. 원격 암호는 Keychain, SSH host key는 연결별 신뢰 기록을 사용한다. 인증서 실패를 자동 무시하지 않는다. 권한 문제가 생겨도 앱 전체를 root로 재실행하지 않는다.

서명·공증·업데이트는 실제 인증서와 배포 인프라 준비가 필요하다. M7에서 산출물 서명 검증, 다운로드 후 Gatekeeper 실행, 이전 버전 설정 마이그레이션을 통과해야 정식 배포 완료다.
