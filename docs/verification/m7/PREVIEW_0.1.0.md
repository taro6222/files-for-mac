# Files for Mac 0.1.0 개발 프리뷰

## 최신 설치 이미지

- 앱 소스 `a07c80c63356097bae3f00790d5147f29956c3b6`, Apple Silicon·Intel 슬라이스.
- 로컬 경로 `build/preview-a07c80c/Files-macOS-preview.dmg`; 옆의 `.sha256`으로 확인한다.
- SHA-256 `2e8fd69f6d98021e058147080331bfabfb9b84ad51402bd5ea7b67894a77509f`.
- macOS 27.2.1(26B131) arm64에서 격리 설치·손상 staging 거부·교체·복원, 설정/두 세션 형식과 fixture 보존을 확인했다. Launch Services 20회 첫 창 표시 p95 278ms, 최대 985ms였다. 공유 OS 캐시 조건이며 실제 입력 수용과 구분한다.
- 창별 탭 순서·선택·프레임·패널 선호 너비 복원, 앱에서 관리하는 탐색 탭과 최신 파일 작업 변경을 포함한다. [실행 및 해시 기록](INCREMENT_336.md)
- ad-hoc 개발 프리뷰다. Developer ID 서명·공증, 새 이미지의 Intel 및 최소 OS 설치·전체 수동 UI 수용은 미완료다. Mach-O의 minos/SDK 14.0 기록은 해당 OS의 실행 증거가 아니다.

## 이전 설치 이미지

- 앱 소스 `40ffc39d4059f09be35e9d7efa6fcb8bd33b559c`, Apple Silicon·Intel 슬라이스, macOS 14.0 배포 대상.
- 로컬 경로 `build/Files-macOS-preview.dmg`. SHA-256 `9179564d9b9cf227d6d43626cbe8ee0a5c859d3f4998698139025289a0f6c103`.
- Apple Silicon Sonoma 14.8.7에서 앱 서명, 교체·복원과 한국어·영어의 실제 업데이트 조회 메뉴를 확인했다. [설치 이미지 검증](INCREMENT_280.md)
- [완료 기록 지우기](INCREMENT_263.md), [작업 센터 키보드 동작](INCREMENT_269.md), [홈 복귀 시 폴더 감시 해제](INCREMENT_268.md), [게시 전 이동 실패 재시도](INCREMENT_272.md)와 [SMB 이동·실행 취소의 파일 시각 수정](INCREMENT_275.md)을 포함한다.

Developer ID 서명·공증, Sonoma 초기 버전과 Sonoma Intel 설치, 콜드 캐시와 장시간 기준은 [출시 검증 현황](RELEASE_GATES.md)에서 추적한다.

## 이전 후보의 검증

- 앱 소스 `32110fa`의 Apple Silicon Sonoma 14.8.7 설치·교체·복원을 확인했다. Launch Services로 20회 실행한 첫 창 표시 p95는 310 ms였다. [Sonoma 검증](INCREMENT_278.md)
- 앱 소스 `80c8b68`의 Apple Silicon Sonoma 14.8.7 설치·교체·복원 및 Launch Services 20회의 창 표시 p95 279 ms를 확인했다. [Sonoma 검증](INCREMENT_270.md)
- 앱 소스 `93af5b7`의 macOS 27.2 [설치·교체·복원](preview-install-93af5b7.json), [메뉴 응답 p95 583 ms](preview-launch-services-93af5b7.json), [PNG·PDF 미리보기](INCREMENT_259.md)를 확인했다.
- Apple Silicon macOS 27.2에서 Launch Services로 20회 열고 접근성 메뉴에서 정보 창을 열었다. 공유 OS 캐시와 동시 부하 시험 조건에서 정보 창 표시 p95는 577 ms, 최대 857 ms였다. [기동 검증](preview-launch-services-0a65838.json)
- 이전 프리뷰 소스의 디버그 AppKit 검증에서 파일 작업은 한국어·영어 × 밝게·어둡게 네 조합마다 68개, 영어·밝은 테마 전체 검사는 270개가 통과했다. [AppKit 회귀](INCREMENT_184.md)
- 파일 작업은 템플릿, 이동 실행 취소·재실행, 복사 취소, 교체 파일 보호 및 재생성된 APFS 폴더 감시 복구를 포함한다.
- 격리 설치의 홈 창 기동은 확인했다. 외부 접근성 조회에서 홈 컨트롤의 상태를 읽지 못했고 WindowServer 캡처도 이미지를 반환하지 않아 설치 앱의 홈 위젯 수동 검증은 남아 있다.
- APFS·대소문자 구분 APFS·exFAT, 시스템 휴지통, 루프백 FTP/FTPS/SFTP 증거는 출시 검증 현황에서 추적한다. 이번 소스에는 테스트 프로세스를 강제 종료한 뒤 교차 볼륨의 교체 이동 실행 취소를 재개한 검증이 포함된다. [강제 종료 복구](INCREMENT_54.md)

이전 프리뷰 소스의 [최적화 QA 탐색 성능](INCREMENT_163.md)에서 10,000항목 전체 표시 p95 1.343초를 기록했다. 이전 최적화 QA에서 10,000항목 전체 표시 p95 1.350초, 100,000항목 최대 샘플 RSS 275 MB를 기록했다. [Release 실측](INCREMENT_12.md)

최근 파일 작업 변경에는 [덮어쓰기 이동의 실행 취소 보호](INCREMENT_125.md), [이동 다시 실행의 메타데이터 검증](INCREMENT_126.md), [FAT32·HFS+ 생성 시간](INCREMENT_133.md), [APFS·exFAT 접근 시간](INCREMENT_135.md)이 포함된다.

이전 후보에는 [상세 목록 분리](INCREMENT_76.md), [전체 Spotlight 인덱스 검색](INCREMENT_78.md), [정보 패널의 다중 항목 미리보기](INCREMENT_79.md) 및 [분할 비율 복원](INCREMENT_83.md)이 들어 있다. 이전 이미지 이후의 [충돌 미리보기](INCREMENT_91.md), [최근 위치만 갱신하는 홈 화면](INCREMENT_93.md), [닫힌 창 콘텐츠 해제](INCREMENT_95.md)도 포함한다. [복사](INCREMENT_101.md)와 [같은 볼륨 이동](INCREMENT_102.md)의 실패 항목 재시도, [일괄 이름 변경의 사전 검사](INCREMENT_103.md), [유휴 뒤 사용자 탐색 처리](INCREMENT_98.md)도 포함한다. [느린 시작 폴더에서 창 표시](INCREMENT_107.md) 개선을 포함한다. [Git 병합 충돌 표시](INCREMENT_108.md)와 [보조 패널 읽기 중단·재시도](INCREMENT_111.md)를 포함한다. Git의 [upstream 동기화](INCREMENT_113.md), [로컬 훅 비활성화](INCREMENT_114.md), [특수 파일명 표시](INCREMENT_116.md)도 포함한다. 또한 [같은 볼륨의 이동 충돌 보호](INCREMENT_148.md)와 [일반 교차 볼륨 이동의 실행 취소 재개](INCREMENT_149.md)를 포함한다. 파일 속성에서 [해시 비교](INCREMENT_152.md)와 [POSIX 권한](INCREMENT_153.md), [확장 ACL 편집](INCREMENT_154.md) 및 [계정 목록](INCREMENT_156.md)을 제공한다. 폴더의 [POSIX 권한](INCREMENT_160.md), [ACL](INCREMENT_161.md), [소유권](INCREMENT_162.md)을 하위 항목에 적용하고 [진행 중 중단](INCREMENT_164.md)할 수 있다. [권한·해시를 포함한 이전 프리뷰의 8시간 결과](INCREMENT_225.md)를 기록했다.

## 포함 기능

- 네이티브 탭·분할 탐색, 상세·그리드·목록·컬럼 및 적응형 보기, 검색, Quick Look, 정보 패널과 Finder 태그.
- 파일 생성·템플릿·복사·이동·충돌 처리·휴지통, 복사·이동 실행 취소와 조건을 충족하는 같은 세션의 이동 재실행.
- ZIP/7z 생성·탐색·추출, RAR 탐색·추출, 클라우드 위치, 원격 연결과 Git 기본 작업.
- 한국어·영어, 시스템·밝게·어둡게, 명령 팔레트, 설정 백업 및 일반 설정 스크롤.

정식 서명·공증, 실제 서비스 환경과 Intel·최소 OS, 시각 비교·접근성 및 장시간 검증은 [출시 검증 현황](RELEASE_GATES.md)에 있다.
