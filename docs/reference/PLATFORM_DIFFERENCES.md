# 플랫폼 차이 및 결정 기록

| 항목 | 현재 결정 | 검증 상태 |
|---|---|---|
| UI | AppKit 네이티브 창·NSTableView. 시스템 언어에 따른 한국어/영어 표시 | arm64 실제 창에서 확인 |
| Windows 재질·창 제어 | macOS sidebar material·traffic lights | 원본 Windows 이미지와의 시각 비교 대기 |
| Windows 전용 실행·셸 | INF 드라이버 설치, 관리자/다른 사용자로 실행, PowerShell 실행, 관리자 Terminal은 macOS 파일 관리자 명령으로 제공하지 않는다. 앱 전체 또는 임의 파일을 root로 실행하지 않으며 Terminal에서 사용자가 명시적으로 권한을 올리는 시스템 흐름을 침범하지 않는다. | M6 `platform-excluded`; 명령 UI에 노출하지 않음 |
| Windows 전용 저장 모델 | NTFS alternate data stream 생성과 Start 메뉴 pin/unpin은 macOS에 동일한 셸 개념이 없어 제공하지 않는다. xattr·Dock/Finder 즐겨찾기를 이름만 같은 기능으로 대체하지 않는다. | M6 `platform-excluded` |
| Windows 실행 환경·상주 기능 | 관리자 실행 경고와 WSL 섹션은 Windows 실행 환경에만 해당한다. FilesMac은 별도 백그라운드 agent나 메뉴 막대 상주 항목을 만들지 않으며 텔레메트리용 영구 사용자 ID도 생성하지 않는다. | M6 `platform-excluded`; lifecycle 또는 분석 기능을 향후 추가하려면 별도 개인정보·배포 설계 필요 |
| 상태센터·요청 프롬프트 | Windows Files의 상태센터 teaching tip과 백그라운드 실행 알림은 제공하지 않는다. 작업 진행은 활성 네이티브 작업 창에서 표시하며 앱 종료 뒤 계속된다고 주장하지 않는다. 리뷰·후원 요청 팝업과 클릭 추적 값도 만들지 않는다. | M6 `platform-excluded`; 별도 background agent나 solicitation UX 없음 |
| 날짜·앱 인스턴스 | 파일 날짜는 별도 앱 형식 목록 대신 macOS 언어·지역 형식을 사용한다. 새 탭은 단일 `NSApplication`의 현재 브라우저 창에 네이티브 탭으로 추가한다. | M6 `platform-alternative`; 한/영 UI 4조합과 탭 UI 검증 |
| 포인터·선택 동작 | 일반 파일 보기는 macOS 표준 더블 클릭으로 열고 명시적 클릭·키보드로 선택한다. 컬럼 보기는 단일 선택으로 다음 계층을 펼친다. Windows touch-only 단일 클릭 모드, hover 선택, 선택 체크박스를 그대로 추가하지 않는다. | M6 `platform-alternative`; 상세·그리드·목록·컬럼 UI QA 및 다중 선택 검증 |
| 고급 설정 | Windows 시작 프로그램·system tray·Explorer/open dialog 대체·thumbnail cache 제어는 macOS 공개 앱 모델에 동일하게 대응하지 않는다. 이식 가능한 설정 관리 목적은 버전 지정 JSON 내보내기와 전체 선검증 후 원자적 가져오기로 제공한다. | M6 `platform-alternative`; 손상·미지원 버전 입력 무변경 단위 테스트 및 네이티브 창 UI 검증 |
| 일반 설정 | 언어와 날짜 형식은 앱 내부 복제 목록 대신 macOS 시스템 설정을 따른다. 시작 세션과 홈 위젯은 앱 설정으로 제공하며 Windows shell context-menu·smooth scrolling 옵션을 거짓 대응하지 않는다. | M6 `platform-alternative`; 네이티브 일반 설정 창 UI 검증 |
| 태그 설정 | 항목의 Finder 태그 이름 편집과 태그 검색은 공개 resource-value API로 제공한다. Windows Files의 앱 소유 전역 태그 목록·임의 색상·정렬 레지스트리와 동일한 공개 Finder API는 없어 별도 전역 편집 화면을 만들지 않는다. | M6 `platform-alternative`; 태그 읽기·쓰기·교체 identity 및 UI 검색 검증 |
| Windows 속성 하위 화면 | 실행 파일 호환성 모드, Windows Libraries, `.lnk` 전용 속성은 macOS 파일 객체에 그대로 적용되지 않는다. 일반·상세·해시·보안 정보는 하나의 네이티브 Get Info 패널로 통합한다. | M6 화면 감사: 3개 제외, 6개 AppKit 대체; ACL 편집은 미구현으로 명시 |
| 드라이브 포맷 | 앱 내부 포맷 대신 선택 볼륨을 macOS Disk Utility에서 연다. 파일 앱이 직접 erase 권한·장치 작업을 소유하지 않는다. | `platform-alternative`; 장착 볼륨 메뉴와 UI 검증 통과 |
| 클래식 속성 | Windows classic properties 대신 macOS 네이티브 정보 패널(Get Info)을 사용한다. | `platform-alternative`; M4 정보 패널 검증 통과 |
| 명령 키 | ⌘L, ⌘[, ⌘], ⌘↑, ⌘↓, ⇧⌘. | 전체 키보드/VoiceOver 흐름 대기 |
| 항목 ID | 경로 기반 directory-entry ID + device/inode/birth 보조 identity | hard link 구분 및 유일한 identity의 외부 rename 선택 복원 통과 |
| 파일 종류 | 기본 메타데이터와 localizedTypeDescription을 분리; 현재 종류는 폴더/확장자 표시 | 부가 API 실패가 폴더 판별을 훼손하지 않도록 수정 |
| 변경 감시 | FSEvents 현재 폴더·직접 자식 관찰 | 로컬 파일 편집·rename 통과; 네트워크 볼륨은 검증 대기 |
| 패키징 | SwiftPM 코어/실행 + 같은 소스를 쓰는 Xcode 앱 타깃 | 정식 배포 전 코어를 별도 패키지 참조로 연결 정리 |
| 휴지통 전체 복원 | 미확정 | 공개 API 실험 대기 |
| 클라우드 상태·명령 | CloudStorage/iCloud 위치를 로컬 탐색; ubiquitous resource value가 있는 항목만 상태 표시하고 공개 FileManager API로 지금 다운로드·공간 비우기 제공. 일반 File Provider 상태는 unknown, 영구 오프라인 유지 명령은 미노출 | fixture 위치·unknown·비지원 명령 무변경·UI 4조합 통과; 실제 공급자별 수용 검증 대기 |
| 원격 연결 | FTP/FTPS는 curl, SFTP는 approved trust+security-scoped identity+username gate 후 OpenSSH 연결, SMB는 Finder | 원격 경로 전용 탐색 모델과 OpenSSH long-listing 디렉터리 metadata 구현; rename overwrite 서버는 업로드 차단 유지 |
| Git | 시스템 `/usr/bin/git`에 상태·clone·fetch·FF-only pull·비강제 push만 위임한다. 자격 증명은 URL에 저장하지 않고 시스템 Git 설정/credential helper/SSH agent에 위임한다. stage·commit·submodule·LFS·hook 실행은 앱 지원 범위 밖이며 UI에 명시한다. | local bare remote·divergence 보존·취소·staging 정리·상태 열·UI 4조합 통과; 인증 HTTPS/SSH 실환경 대기 |
| 압축 backend | macOS 시스템 libarchive 직접 연결; ZIP/7z 생성·탐색·안전 추출, RAR 탐색·안전 추출; 암호·분할·수정은 미지원 | ZIP/7z Unicode 생성·재열기·추출, 공식 7z/RAR fixture, 앱 UI 4조합 통과 |
| Intel/최소 OS | 배포 타깃만 설정 | 실기기 실행 대기 |
