# 개발 현황

갱신: 2026-11-14

## 이번 구현 단위

분할 보기의 보조 패널에 탐색 버튼의 접근성 이름과 상태, 상세 파일 목록 이름을 추가했다. [M7 보조 패널 접근성](verification/m7/INCREMENT_41.md)

최신 유니버설 프리뷰의 시작부터 메뉴 명령 응답까지 20회 측정했다. [M7 프리뷰 상호작용 시간](verification/m7/INCREMENT_40.md)

대형 폴더를 읽을 때 새 항목만 정렬해 기존 목록에 병합한다. [M7 대형 폴더 정렬과 성능](verification/m7/INCREMENT_39.md)

명령 팔레트가 연 브라우저 창에서 명령을 실행하고, Esc로 닫으면 이전 컨트롤에 초점을 돌려준다. [M7 명령 팔레트 키보드 검증](verification/m7/INCREMENT_38.md)

사이드바를 숨겨도 방향키와 Return으로 홈에서 네트워크 위치를 열고 파일 보기에 초점을 옮길 수 있다. [M7 홈 키보드 탐색](verification/m7/INCREMENT_37.md)

SMB 마운트가 응답하지 않을 때 검증 명령이 시간 제한을 적용하고 실패를 반환한다. [M7 SMB 마운트와 검증 제한 시간](verification/m7/INCREMENT_36.md)

마운트된 네트워크 볼륨을 홈의 네트워크 위치에서 열 수 있다. [M7 홈 네트워크 위치](verification/m7/INCREMENT_35.md)

Windows 원본 탐색 화면의 XAML과 macOS 캡처를 대조하고 상태 표시줄의 개발 단계 문구를 제거했다. [탐색 화면 대조](reference/UI_BASELINE.md)

폴더 감시 복구와 최근 파일 작업 변경을 포함한 0.1.0 유니버설 프리뷰를 다시 빌드했다. [개발 프리뷰 확인](verification/m7/PREVIEW_0.1.0.md)

삭제 후 같은 경로에 다시 생긴 폴더에서 읽기와 자동 갱신을 복구한다. [M7 폴더 감시 복구](verification/m7/INCREMENT_34.md)

장시간 시험에서 탐색 이력 크기를 일정하게 유지하고 RSS 표본별 경과 시간을 기록한다. [M7 장시간 메모리 계측](verification/m7/INCREMENT_33.md)

8 MiB 복사 검증 단계에 취소를 주입해 상태 반영·정리 시간을 기록했다. [M7 복사 동작 중 취소](verification/m7/INCREMENT_32.md)

AppKit 복사 취소 액션의 상태 반영을 네 언어·테마 조합에서 측정했다. [M7 취소 피드백](verification/m7/INCREMENT_31.md)

스크롤을 제외한 대조군에서도 캡처 간격 p95가 약 33ms로 나타났다. [M7 캡처 대조군](verification/m7/INCREMENT_30.md)

일반 파일 아이콘에서 확장자 타입 조회를 재사용한다. [M7 일반 아이콘 캐시](verification/m7/INCREMENT_29.md)

60Hz 화면 갱신에 맞춘 스크롤에서도 창 갱신 간격 p95는 약 33ms였다. [M7 스크롤 입력 비교](verification/m7/INCREMENT_28.md)

60Hz 창 캡처에서 10,000항목 스크롤 갱신 간격 p95 33.41ms를 기록했다. [M7 창 프레임 측정](verification/m7/INCREMENT_27.md)

Release AppKit에서 10,000항목 목록 연속 스크롤을 실행했다. 화면 프레임 표본은 추가 확보가 필요하다. [M7 스크롤 계측](verification/m7/INCREMENT_26.md)

512 MiB 단일 파일에서 검증을 포함한 네이티브 복사 기준 처리량의 102.95%를 기록했다. [M7 네이티브 복사 비교](verification/m7/INCREMENT_25.md)

512 MiB 검증 복사 시간 중앙값이 0.964초에서 0.586초로 줄었다. [M7 복사 처리량](verification/m7/INCREMENT_24.md)

복사 검증의 중복 해시 읽기를 줄이고 게시 전에 실행 취소 정보를 확보한다. [M7 복사 검증](verification/m7/INCREMENT_23.md)

최초 v1 설정 구조의 가져오기·저장을 검사하고 지원 범위 밖의 스키마를 명확히 안내한다. [M7 이전 설정 가져오기](verification/m7/INCREMENT_22.md)

다운로드한 정식 DMG의 체크섬·서명·공증 티켓과 내부 앱의 배포 정책을 검사하는 경로를 추가했다. [M7 다운로드 검증](verification/m7/INCREMENT_21.md)

장시간 시험에서 실행 중 작업 트리가 바뀌어도 기록한 커밋과 바이너리가 일치하도록 커밋 스냅샷에서 빌드한다. [M7 장시간 시험 소스 고정](verification/m7/INCREMENT_20.md)

교체 이동 취소 후 기존 대상을 자동 복원하지 못하면 결과 창과 작업 저널에 백업 경로를 남긴다. [M7 교체 이동 복구](verification/m7/INCREMENT_19.md)

교차 볼륨 교체 이동 중 취소하면 원본·기존 대상이 보존되는지 실제 로컬 볼륨에서 검사했다. 같은 시험을 SMB 검증 경로에 추가했다. [M7 교체 이동 중단](verification/m7/INCREMENT_18.md)

유니버설 DMG에 포함된 양쪽 아키텍처의 macOS 14.0 배포 대상과 코드 서명을 확인한다. [M7 유니버설 배포 대상](verification/m7/INCREMENT_17.md)

정식 DMG 배치 전에 공증 승인과 최종 이미지 무결성을 확인한다. 모의 실패 경로에서 기존 산출물을 보존하는지 검증했다. [M7 배포 이미지 검증](verification/m7/INCREMENT_16.md)

이동 충돌 창에서 ⌘S로 기존 대상과 원본을 보존하는 경로를 확인했다. 이동 진행률·결과에 접근성 이름과 상태 알림을 추가했다. [M7 이동 접근성](verification/m7/INCREMENT_15.md)

복사 충돌을 키보드로 건너뛰고 결과를 닫는 동작을 확인했다. 진행률·결과 접근성 이름과 상태 알림을 추가했다. [M7 복사 접근성](verification/m7/INCREMENT_14.md)

실제 exFAT에서 일괄 이름 교환을 보완하고, 이름 충돌 시 부분 완료와 복구 결과를 검증했다. [M7 exFAT 일괄 이름 변경](verification/m7/INCREMENT_13.md)

로컬 목록의 식별자 조회를 간소화해 10,000항목 전체 표시 p95 1.350초를 기록했고 exFAT 단일 항목 이름 변경을 보완했다. [M7 대형 폴더·exFAT](verification/m7/INCREMENT_12.md)

프리뷰 새 프로세스 20회에서 창이 등록되기까지 p95 248 ms를 기록했다. [M7 프리뷰 시작 시간](verification/m7/INCREMENT_11.md)

프리뷰를 격리 경로에 설치하고 손상된 교체본 거부, 정상 교체, 이전 앱 복원과 설정 유지 동작을 확인했다. [M7 설치·복원 검증](verification/m7/INCREMENT_10.md)

프리뷰 설치 이미지와 앱에 라이선스를 넣고, 이미지에 설치·복구 안내와 검증 범위를 포함했다. [M7 설치 이미지 검증](verification/m7/INCREMENT_09.md)

8시간 탐색·탭·전송 검증을 자동화했다. 예비 실행에서 28사이클을 완료했다. [M7 장시간 검증](verification/m7/INCREMENT_08.md)

현재 표시하는 보기를 중심으로 갱신하도록 개선했다. 최적화 QA에서 10,000항목 전체 표시 p95 1.842초를 기록했다. [M7 활성 보기 렌더링](verification/m7/INCREMENT_07.md)

최적화 빌드에서 10,000·100,000항목을 검증했다. 100,000항목 최대 샘플 RSS는 1,623 MB에서 366 MB로 줄었다. 전체 표시 성능은 검증 목표를 넘겨 추가 개선 대상으로 유지한다. [M7 Release 성능 계측](verification/m7/INCREMENT_06.md)

일반 설정 개선을 포함한 0.1.0 유니버설 로컬 프리뷰를 다시 빌드했다. 최신 DMG와 검증 정보는 [개발 프리뷰 릴리스 노트](verification/m7/PREVIEW_0.1.0.md)에 기록했다.

M7 첫 개발 단위로 로컬 프리뷰 DMG를 빌드하고 마운트·실행을 검증했다. 정식 서명·공증은 자격 증명 준비 중이다. [M7 로컬 프리뷰 검증](verification/m7/INCREMENT_01.md)

로컬 릴리스 검증에서 실제 APFS·대소문자 구분 APFS·exFAT, 시스템 휴지통 및 루프백 FTP/FTPS/SFTP를 재검증했다. AppKit 20회 왕복·100개 스크롤 표본을 기록했다. [M7 로컬 회귀·성능](verification/m7/INCREMENT_02.md)

대형 폴더의 중간 목록 표시를 합쳤고, 이번 10,000항목 전체 AppKit 표시가 1.803초로 측정됐다. [M7 대형 폴더 표시](verification/m7/INCREMENT_03.md)

Apple Silicon과 Intel 슬라이스를 포함한 새 프리뷰 DMG를 생성했다. Apple Silicon에서 마운트·실행을 확인했다. [M7 유니버설 DMG](verification/m7/INCREMENT_04.md) · [남은 출시 검증](verification/m7/RELEASE_GATES.md)

일반 설정 창에서 세로 스크롤을 적용하고 마지막 옵션까지 도달하는 동작을 확인했다. [M7 일반 설정 검증](verification/m7/INCREMENT_05.md)

M6 103번째 개발 단위로 사용자가 선택한 파일을 템플릿으로 재사용하는 기능을 추가했다. 명령·설정·화면 인벤토리에서 검토 대기 항목은 0개다. 대응 범위 밖의 동작과 실환경 검증은 계속 추적한다.

| 영역 | 상태 | 내용 |
|---|---|---|
| 원격 기반 | 완료 | 지정 origin의 초기 LICENSE/이력 보존 |
| 기준 원본 | 완료 | v4.2.9/SHA 고정 |
| 원본 인벤토리 | 진행 | 202 명령·143 설정·33 화면 감사 통과. 명령 155개 구현·29개 macOS 대체·18개 플랫폼 제외·0개 검토 대기, 설정 64개 구현·60개 macOS 대체·19개 플랫폼 제외·0개 검토 대기, 화면 29개 macOS 대체·4개 플랫폼 제외·0개 검토 대기 |
| 네이티브 앱 | 구현 | AppKit 창·네이티브 탭 그룹·사이드바·홈·상세 목록·경로 |
| 로컬 I/O | 검증 | 배치 열거·숨김 항목·메타데이터·파일 identity·오류 상태 |
| 탐색 상태 | 검증 | 히스토리·선택 복원·외부 rename 대응·오래된 비동기 결과 방지 |
| 파일 목록 | 구현 | 다중 선택·자연 정렬·열 정렬/재배치/크기 저장, 상세 보기 Git 상태 열과 하위 변경 집계 |
| 보기 모드 | 구현 중 | 양쪽 pane 상세·그리드·단일열 목록·계층형 컬럼 및 적응형 정책, 작게/보통/크게 프리셋 저장, 선택 identity·스크롤·세션·파일 작업 보존 |
| 편의 기능 | 구현 | 경로 추천·확장자 옵션·공유 즐겨찾기 순서·홈 용량·최근 기록 삭제 |
| 명령 팔레트 | 구현 | 메인 메뉴 자동 인덱싱, 다국어 부분 검색, 문맥별 활성 조건, 단축키 표시, 키보드 실행·취소 |
| 단축키 | 구현 | 실제 keyDown recorder, 사용자 override 저장, 중복·수정키 없음·macOS 예약 조합 차단, 기본값 복원 |
| 툴바 | 구현 | 항목 표시·숨김, 순서 변경, 필수 경로 필드 보호, 좁은 창 overflow, 전체 창 즉시 반영과 재실행 저장 |
| 외형 | 구현 | 시스템 설정·밝게·어둡게 즉시 전환과 저장, 안전한 앱 관리 이미지 배경·모든 보기/pane 즉시 반영·초기화, macOS sidebar 재질의 대비·투명도 접근성 설정 추종 |
| 폴더별 설정 | 구현 | 표준 경로별 보기 모드·크기 저장, 양쪽 pane 적용, 폴더 설정 우선·해제 시 전역값 복귀, 손상 JSON 복구 |
| 설정 관리 | 구현 | 저장된 폴더별 보기 개수 표시, 전체 초기화, 초기화 즉시 모든 창 반영 |
| 검색 | 검증 | ⌘F 패널, 직접 열거 파일명/Spotlight 콘텐츠 adapter, 실제 인덱스 hit, 범위·종류·숨김·Finder 태그·B/KB/MB/GB 최소·최대 크기·수정 날짜 필터 및 입력 오류 표시, 인덱스 범위 안내, 진행·중단·부분 결과·접근 실패, 결과 열기 |
| 정보·속성 | 구현 중 | ⌘I 패널, 다중 선택 요약, 논리/할당 크기, 날짜, 소유자·그룹·POSIX 권한, UTI, Finder 태그, 볼륨, 접근 상태, SHA-256 진행·취소 |
| 미리보기 | 구현 중 | Space/메뉴 네이티브 QLPreviewPanel, 선택 항목 datasource, 다중 선택 탐색, 패널 종료 시 datasource 해제 |
| Finder 태그 | 구현 중 | 정보 패널 편집, resource-value 읽기·쓰기, 공백·중복 정규화, 제어문자 차단, identity 재검증, 폴더 감시 갱신 |
| 드라이브 | 구현 중 | 장착/해제 알림 갱신, 이름·용량·여유 공간·포맷·내장/로컬/읽기 전용·제거 가능 capability, 홈 사용량·사이드바 탐색, 파일 작업 차단형 안전 추출, Disk Utility 연결 |
| 시스템 열기 | 구현 | 기본 연결 앱, Finder에서 보기, macOS 공유 picker, Terminal에서 위치 열기, 사용자가 선택한 앱/IDE로 열기; URL 기반 전달 |
| 압축 | 구현 중 | ZIP/7z 생성·탐색·안전 추출, RAR 탐색·안전 추출, 현재 폴더·스마트 위치·아카이브별 고유 하위 폴더 추출, 다중 선택 순차 처리, 링크/특수 항목 거부·변경 재검증, staging/publish/rollback, AppKit UI·중단·항목/바이트 진행률 |
| 클라우드 | 구현 중 | `~/Library/CloudStorage` 공급자 폴더와 iCloud Drive 탐지·사이드바 탐색, ubiquitous resource value 기반 상태 분류, iCloud 지금 다운로드·공간 비우기 메뉴, 일반 File Provider 상태는 unknown·명령 비활성 유지 |
| 원격 연결 | 구현 중 | FTP/암시적 FTPS·SFTP 원격 pane 탐색·중단·세션·접근성·안전 다운로드, FTPS 인증서·호스트 검증, Keychain 자격 증명 게이트, FTP Unix·Windows/DOS LIST 폴더 metadata와 미지원 형식 차단, unsafe rename 업로드 차단 |
| Git | 구현 중 | 상태 패널과 clone UI, HTTPS/SSH/file 입력, sibling staging publish, 완료 후 새 탐색 창, fetch/FF-only pull/push/중단, 상세 목록 XY 상태·폴더 하위 변경 표시, 탐색 중 stale 결과 폐기·선택 보존, stage/commit·submodule·LFS·hook 제외와 시스템 인증 위임을 UI에 명시 |
| 테스트 | 통과 | Swift Testing 201개. 한국어·영어 × 밝게·어둡게 AppKit 기본 회귀 각 218개, 파일 작업 회귀 각 31개. 템플릿 이름 입력과 원본·생성 파일의 내용 확인 |
| 파일 복사 | 구현 | 대상 폴더 선택·클립보드·양쪽 유지/건너뛰기·내용 검증·취소·항목별 결과·JSON 저널·안전 실행 취소, 다중 선택 폴더 병합·통합 Undo |
| 느린 폴더 복구 | 구현 | 읽기 중단·늦은 결과 차단·불완전 목록 안내·명시적 재시도 |
| 접근 복구 | 부분 검증 | 오류 화면 재시도·폴더 선택, 시스템 선택 후 Desktop fixture 읽기 성공; 재실행 읽기 확인; 감시는 연결 대기 |
| 실제 UI | 부분 확인 | 900×600·한/영·두 테마·10k 상세/그리드/목록/3단 컬럼·POSIX 권한 오류, 분할 pane 보기·M2 병합·Undo·ZIP 목록/추출 4조합 확인, 이미지 보관 |
| 폴더 감시 | 검증 | 연결 중/실패 구분, 명시적 재등록, 등록 실패 후 복구·실제 변경 반영 |
| 생성·이름 변경 | 구현 | 새 폴더, 선택 항목으로 새 폴더, 단일 이름 검증, 배치 패턴·미리보기·충돌 검사·순환 교환·결과 창 |
| 탭 탐색 | 구현 중 | 네이티브 탭 생성·복제·순서 변경/분리 기반, 탭별 히스토리·선택·스크롤·정렬·숨김 설정, 닫은 탭 및 재실행 복원 |
| 분할 보기 | 구현 중 | 실제 두 목록, pane별 탐색·파일 작업·FSEvents 감시·숨김·정렬, 분할 축·비율·활성 pane·두 상태 복원 |
| 드래그 앤 드롭 | 구현 중 | 상세·그리드·목록·컬럼 양쪽 pane 파일 URL 송수신, 폴더/현재 위치 drop, Option 복사·Command 이동, 안전 엔진 및 충돌 대화상자 연결; file promise는 미구현 |
| 휴지통 이동 | 검증 | 항목별 결과 표시·실패 분리·저널 기록, 실제 시스템 휴지통 이동 성공 |
| 휴지통 복원 | 검증 | 휴지통 항목 선택 복원(대상 폴더 선택) 동작과 `restoreFromTrash` 결과 창 연결, 실제 시스템 휴지통 왕복 복원·내용 확인 성공 |
| 이동 | 구현 중 | 동일/교차 볼륨 이동, 검증·교체 백업·안전 실행 취소, 사용자 취소, 단계별 상태와 진행 막대; APFS/APFSX/exFAT 통과 |
| 영구 삭제 | 구현 중 | 선택 항목 영구 삭제(복구 불가 경고), 항목별 상태 보고, 작업 창, 저널 파일 |

다음 구현은 속성·설정·shell 화면을 개별 대응하고, 실제 UI가 없는 화면은 구현 과제로 분리한다. M5 실환경 게이트는 M7 전 필수 재검증으로 유지한다.

## M1 별도 검증 목록

1. 10,000항목 compositor 첫 frame·입력 기반 연속 스크롤 FPS 측정. AppKit 처리 기준 반복 표본·p95 측정 도구를 추가했다.
2. 키보드 전체 흐름/VoiceOver/TCC 검증. 시스템 폴더 선택 후 Desktop 테스트 폴더 읽기·수동 새로고침 성공을 확인했다. 자동 감시와 재실행 후 접근 유지, 대기의 근본 원인은 별도 검증이 필요하다.
3. 원본 Windows 캡처와 표 헤더·폰트·간격 대조. macOS fixture 기반 4조합 목록 이미지는 보관 완료.
4. macOS 최소 버전·Intel·네트워크 볼륨에서 감시/볼륨 제거 시험. APFS/APFSX/exFAT 임시 실제 볼륨의 파일 작업은 통과했지만 원격 파일 시스템의 이벤트 전달 차이 검증은 남아 있다.
5. 사이드바 섹션 접힘·순서 저장과 재실행 복원은 완료. 두 창의 설정·선택 유지와 5회 왕복 탐색, 닫힌 창 객체 해제를 4조합에서 확인했다. 장시간 조작은 남아 있다.

위 목록은 환경별 검증 과제로 유지하며 M2 진입의 선행 조건에서 분리했다. M1 전체 통과로 표시하지 않는다.

## M2 다음 구현

복사와 안전 실행 취소, 새 폴더, 선택 항목으로 새 폴더, 단일·배치 이름 변경, 휴지통 이동·복원, 영구 삭제, 안전한 이동과 드래그 앤 드롭을 두 pane에 연결했다. 다중 선택 병합은 누락 복사·재귀 병합·충돌 보존을 한 작업과 하나의 Undo로 처리한다.

## 변경 규칙

현재 구현을 완전 기능 앱 또는 원본 UI 완전 일치로 표시하지 않는다. 각 단계 종료 시 검증 결과와 문서를 갱신하고 관련 변경을 커밋한 뒤 origin에 푸시한다. 사용자가 이 절차를 상시 승인했다. 각 개발 단위는 M0/M1/M2 진행 상태를 정확히 표시해 커밋한다. [두 번째 개발 단위 검증](verification/m1/INCREMENT_02.md)을 참고한다.

최근 검증: [M2 새 폴더와 이름 변경](verification/m2/INCREMENT_03.md), [M2 휴지통 이동](verification/m2/INCREMENT_04.md), [M2 휴지통 복원 준비](verification/m2/INCREMENT_05.md), [M2 영구 삭제](verification/m2/INCREMENT_06.md), [M2 이동 기본 동선](verification/m2/INCREMENT_07.md), [M2 안전한 이동 실행 취소](verification/m2/INCREMENT_08.md), [M2 교차 볼륨 이동](verification/m2/INCREMENT_09.md), [M2 교체 백업과 실행 취소](verification/m2/INCREMENT_10.md), [M2 이동 취소와 진행 표시](verification/m2/INCREMENT_11.md), [M2 배치 이름 변경](verification/m2/INCREMENT_12.md), [M2 배치 이름 변경 패턴 UI](verification/m2/INCREMENT_13.md), [M2 네이티브 탭 기반](verification/m2/INCREMENT_14.md), [M2 탭 상태 및 세션 복원](verification/m2/INCREMENT_15.md), [M2 분할 pane 상태 모델](verification/m2/INCREMENT_16.md), [M2 AppKit 분할 탐색 UI](verification/m2/INCREMENT_17.md), [M2 활성 pane 파일 작업](verification/m2/INCREMENT_18.md), [M2 분할 workspace 세션](verification/m2/INCREMENT_19.md), [M2 보조 pane 감시·보기](verification/m2/INCREMENT_20.md), [M2 Finder 드래그 앤 드롭](verification/m2/INCREMENT_21.md), [M2 선택 항목으로 새 폴더](verification/m2/INCREMENT_22.md), [M2 안전한 복사 실행 취소](verification/m2/INCREMENT_23.md), [M2 폴더 병합 계획](verification/m2/INCREMENT_24.md), [M2 폴더 병합 실행](verification/m2/INCREMENT_25.md), [M2 폴더 병합 UI](verification/m2/INCREMENT_26.md), [M2 다중 선택 폴더 병합](verification/m2/INCREMENT_27.md), [M2 AppKit 통합 검증](verification/m2/INCREMENT_28.md), [M2 장애 주입](verification/m2/INCREMENT_29.md), [M2 실제 볼륨 매트릭스](verification/m2/INCREMENT_30.md), [M2 시스템 휴지통 왕복](verification/m2/INCREMENT_31.md), [M2 SMB 수용 검증기](verification/m2/INCREMENT_32.md).

M3 검증: [보기 모드 상태와 세션 호환성](verification/m3/INCREMENT_01.md), [pane별 보기 모드 컨트롤](verification/m3/INCREMENT_02.md), [기본 pane 그리드 렌더러](verification/m3/INCREMENT_03.md), [보조 pane 그리드와 선택 경쟁 수정](verification/m3/INCREMENT_04.md), [그리드 명령 및 드래그 앤 드롭](verification/m3/INCREMENT_05.md), [양쪽 pane 단일열 목록 렌더러](verification/m3/INCREMENT_06.md), [양쪽 pane 계층형 컬럼 렌더러](verification/m3/INCREMENT_07.md), [적응형 보기 정책](verification/m3/INCREMENT_08.md), [보기 크기 프리셋](verification/m3/INCREMENT_09.md), [컬럼 파일 작업 통합](verification/m3/INCREMENT_10.md), [네이티브 명령 팔레트](verification/m3/INCREMENT_11.md), [사용자 단축키 설정](verification/m3/INCREMENT_12.md), [툴바 사용자 지정](verification/m3/INCREMENT_13.md), [외형 설정](verification/m3/INCREMENT_14.md), [폴더별 보기 설정](verification/m3/INCREMENT_15.md), [폴더별 설정 관리](verification/m3/INCREMENT_16.md).

M4 검증: [로컬 파일명 검색 코어](verification/m4/INCREMENT_01.md), [검색 상태와 취소](verification/m4/INCREMENT_02.md), [네이티브 검색 패널](verification/m4/INCREMENT_03.md), [파일 속성과 SHA-256](verification/m4/INCREMENT_04.md), [네이티브 정보 패널](verification/m4/INCREMENT_05.md), [Quick Look](verification/m4/INCREMENT_06.md), [Finder 태그 코어](verification/m4/INCREMENT_07.md), [Finder 태그 편집 UI](verification/m4/INCREMENT_08.md), [검색 메타데이터 필터](verification/m4/INCREMENT_09.md), [검색 고급 필터 UI](verification/m4/INCREMENT_10.md), [Spotlight 콘텐츠 검색](verification/m4/INCREMENT_11.md), [장착 볼륨 capability](verification/m4/INCREMENT_12.md), [안전 추출과 Disk Utility](verification/m4/INCREMENT_13.md), [시스템 열기 명령](verification/m4/INCREMENT_14.md), [실제 볼륨 탐지 매트릭스](verification/m4/INCREMENT_15.md), [검색 크기 단위](verification/m4/INCREMENT_16.md), [실제 Spotlight 콘텐츠 hit](verification/m4/INCREMENT_17.md).

M5 검증: [압축 추출 보안 validator](verification/m5/INCREMENT_01.md), [libarchive ZIP 안전 추출](verification/m5/INCREMENT_02.md), [ZIP 안전 생성](verification/m5/INCREMENT_03.md), [ZIP 탐색·추출 UI](verification/m5/INCREMENT_04.md), [ZIP 생성 UI](verification/m5/INCREMENT_05.md), [압축 정량 진행률](verification/m5/INCREMENT_06.md), [포맷 capability·오류 안내](verification/m5/INCREMENT_07.md), [7z/RAR 탐색·안전 추출](verification/m5/INCREMENT_08.md), [7z 안전 생성](verification/m5/INCREMENT_09.md), [압축 worker 취소 수용](verification/m5/INCREMENT_10.md).
[클라우드 위치·상태 탐지](verification/m5/INCREMENT_11.md), [iCloud 다운로드·공간 비우기 명령](verification/m5/INCREMENT_12.md), [원격 연결 프로필 기반](verification/m5/INCREMENT_13.md), [원격 프로필 저장·Keychain](verification/m5/INCREMENT_14.md), [원격 연결 관리 UI](verification/m5/INCREMENT_15.md), [SMB 표준 연결 adapter](verification/m5/INCREMENT_16.md), [원격 backend·보안 명령 계획](verification/m5/INCREMENT_17.md), [원격 subprocess 실행·취소](verification/m5/INCREMENT_18.md), [FTP/FTPS 목록 provider](verification/m5/INCREMENT_19.md), [FTP/FTPS 안전 다운로드](verification/m5/INCREMENT_20.md), [FTP/FTPS staging 업로드](verification/m5/INCREMENT_21.md), [localhost FTP 실제 수용 검증](verification/m5/INCREMENT_22.md), [FTP rename capability probe](verification/m5/INCREMENT_23.md), [SFTP strict trust 명령 계약](verification/m5/INCREMENT_24.md), [SFTP private config executor](verification/m5/INCREMENT_25.md), [SFTP host fingerprint 저장소](verification/m5/INCREMENT_26.md), [SFTP host key 승인 UI](verification/m5/INCREMENT_27.md), [SFTP 개인키 bookmark UI](verification/m5/INCREMENT_28.md), [SFTP 목록 연결 UI](verification/m5/INCREMENT_29.md), [SFTP 안전 staging 전송](verification/m5/INCREMENT_30.md), [localhost OpenSSH SFTP 수용 검증](verification/m5/INCREMENT_31.md), [SFTP 다운로드 작업 UI](verification/m5/INCREMENT_32.md), [SFTP host-key mismatch 수용](verification/m5/INCREMENT_33.md), [SFTP 대용량 취소 수용](verification/m5/INCREMENT_34.md), [원격 탐색 상태 모델](verification/m5/INCREMENT_35.md), [AppKit 원격 탐색 pane](verification/m5/INCREMENT_36.md), [원격 pane UI 수용](verification/m5/INCREMENT_37.md), [원격 pane 세션 보존](verification/m5/INCREMENT_38.md), [원격 pane 키보드·접근성](verification/m5/INCREMENT_39.md), [FTP LIST 폴더 metadata](verification/m5/INCREMENT_40.md), [FTP/FTPS 원격 pane 연결](verification/m5/INCREMENT_41.md), [FTPS TLS 실제 수용](verification/m5/INCREMENT_42.md), [FTP DOS LIST·미지원 형식 차단](verification/m5/INCREMENT_43.md), [Git 상태·브랜치 기반](verification/m5/INCREMENT_44.md), [Git bare remote 안전 작업](verification/m5/INCREMENT_45.md), [Git divergence 보존](verification/m5/INCREMENT_46.md), [Git 취소·staging 정리](verification/m5/INCREMENT_47.md), [AppKit Git 상태 패널](verification/m5/INCREMENT_48.md), [AppKit Git clone UI](verification/m5/INCREMENT_49.md), [상세 목록 Git 상태 열](verification/m5/INCREMENT_50.md), [Git 지원 경계 UI](verification/m5/INCREMENT_51.md), [M5 종료 감사 단위](verification/m5/INCREMENT_52.md), [M5 종료 감사](verification/m5/EXIT_AUDIT.md).

M6 검증: [인벤토리 자동 감사 게이트](verification/m6/INCREMENT_01.md), [첫 명령 대응 매핑](verification/m6/INCREMENT_02.md), [파일 작업 명령 매핑](verification/m6/INCREMENT_03.md), [압축·Git·시스템 명령 매핑](verification/m6/INCREMENT_04.md), [플랫폼 차이 명령 판정](verification/m6/INCREMENT_05.md), [선택 해제·반전 명령](verification/m6/INCREMENT_06.md), [3상태 정렬 명령](verification/m6/INCREMENT_07.md), [첫 설정 대응 매핑](verification/m6/INCREMENT_08.md), [시작 세션 복원 설정](verification/m6/INCREMENT_09.md), [네이티브 레이아웃 설정 대응](verification/m6/INCREMENT_10.md), [Windows 전용 설정 판정](verification/m6/INCREMENT_11.md), [툴바·상태 막대 표시 설정](verification/m6/INCREMENT_12.md), [탐색·외형 화면 대응](verification/m6/INCREMENT_13.md), [속성 화면 대응](verification/m6/INCREMENT_14.md), [설정·shell 화면 대응](verification/m6/INCREMENT_15.md), [About·릴리스 노트 화면](verification/m6/INCREMENT_16.md), [macOS 코드 서명 정보](verification/m6/INCREMENT_17.md), [개발 앱 설정](verification/m6/INCREMENT_18.md), [폴더 아이콘 사용자 지정](verification/m6/INCREMENT_19.md), [설정 내보내기·가져오기](verification/m6/INCREMENT_20.md), [일반·Finder 태그 설정 화면](verification/m6/INCREMENT_21.md), [시작 폴더 설정](verification/m6/INCREMENT_22.md), [네이티브 수명주기·날짜 정책](verification/m6/INCREMENT_23.md), [파일 크기 단위](verification/m6/INCREMENT_24.md), [폴더 새 탭 열기](verification/m6/INCREMENT_25.md), [상위 이동 폴더 복원](verification/m6/INCREMENT_26.md), [파일 확장자 변경 경고](verification/m6/INCREMENT_27.md), [macOS 포인터·선택 동작](verification/m6/INCREMENT_28.md), [사이드바 표시 설정](verification/m6/INCREMENT_29.md), [상세 열 표시 설정](verification/m6/INCREMENT_30.md), [네이티브 스크롤 정책](verification/m6/INCREMENT_31.md), [컨텍스트 메뉴 표시 설정](verification/m6/INCREMENT_32.md), [사이드바 고정 메뉴](verification/m6/INCREMENT_33.md), [macOS 공유 메뉴 대응](verification/m6/INCREMENT_34.md), [경로 복사 명령](verification/m6/INCREMENT_35.md), [새 탭·창·pane 열기](verification/m6/INCREMENT_36.md).

M6 추가 검증: [Finder 태그 편집 메뉴](verification/m6/INCREMENT_37.md).
M6 추가 검증: [Windows 셸 확장 메뉴 경계](verification/m6/INCREMENT_38.md).
M6 추가 검증: [압축 해제 위치 명령](verification/m6/INCREMENT_48.md).
M6 추가 검증: [macOS 시스템 배경 명령](verification/m6/INCREMENT_49.md).
M6 추가 검증: [앱 사용자 지정 배경](verification/m6/INCREMENT_50.md).
M6 추가 검증: [안전한 이미지 좌우 회전](verification/m6/INCREMENT_51.md).
M6 추가 검증: [시스템 설치·미디어 열기 명령](verification/m6/INCREMENT_52.md).
M6 추가 검증: [선택 토글·Finder 태그 명령](verification/m6/INCREMENT_53.md).
M6 추가 검증: [상세 열 너비 자동 맞춤](verification/m6/INCREMENT_54.md).
M6 추가 검증: [휴지통 전용 그룹화 경계](verification/m6/INCREMENT_55.md).
M6 추가 검증: [일반 파일 그룹 코어](verification/m6/INCREMENT_56.md).
M6 추가 검증: [그룹 상태 저장·복원](verification/m6/INCREMENT_57.md).
M6 추가 검증: [그리드 그룹 섹션](verification/m6/INCREMENT_58.md).
M6 추가 검증: [목록 그룹 행](verification/m6/INCREMENT_59.md).
M6 추가 검증: [상세 그룹 행](verification/m6/INCREMENT_60.md).
M6 추가 검증: [일반 그룹 명령](verification/m6/INCREMENT_61.md).
M6 추가 검증: [생성일 정렬·그룹화](verification/m6/INCREMENT_62.md).
M6 추가 검증: [생성일 상세 열](verification/m6/INCREMENT_63.md).
M6 추가 검증: [네이티브 탭 명령](verification/m6/INCREMENT_64.md).
M6 추가 검증: [진단·도움말 열기 명령](verification/m6/INCREMENT_65.md).
M6 추가 검증: [컴팩트 오버레이 창 모드](verification/m6/INCREMENT_66.md).
M6 추가 검증: [위치별 열기·활성 pane 닫기](verification/m6/INCREMENT_67.md).
M6 추가 검증: [macOS 통합 사이드바 설정](verification/m6/INCREMENT_68.md).
M6 추가 검증: [홈 위젯 접힘 상태](verification/m6/INCREMENT_69.md).
M6 추가 검증: [카드 레이아웃·보기 크기 명령](verification/m6/INCREMENT_70.md).
M6 추가 검증: [클립보드 잘라내기·붙여넣기](verification/m6/INCREMENT_71.md).
M6 추가 검증: [선택 폴더·심볼릭 링크 붙여넣기](verification/m6/INCREMENT_72.md).
M6 추가 검증: [Finder 태그 정렬·그룹화](verification/m6/INCREMENT_73.md).
M6 추가 검증: [폴더 경로 정렬·그룹화](verification/m6/INCREMENT_74.md).
M6 추가 검증: [홈·사이드바 위치 작업](verification/m6/INCREMENT_75.md).
M6 추가 검증: [Git 초기화·안전 동기화](verification/m6/INCREMENT_76.md).
M6 추가 검증: [Finder 태그·경로 상세 열](verification/m6/INCREMENT_77.md).
M6 추가 검증: [기본 파일·폴더 정렬 배치](verification/m6/INCREMENT_78.md).
M6 추가 검증: [상세 열 자동 맞춤 정책](verification/m6/INCREMENT_79.md).
M6 추가 검증: [시작 새 탭·선택 탭 복원](verification/m6/INCREMENT_80.md).
M6 추가 검증: [새 탭 dual-pane·전환 정책](verification/m6/INCREMENT_81.md).
M6 추가 검증: [macOS 테마 토큰·앱 배경 소스](verification/m6/INCREMENT_82.md).
M6 추가 검증: [앱 배경 표시 제어](verification/m6/INCREMENT_83.md).
M6 추가 검증: [취소 가능한 폴더 크기 계산](verification/m6/INCREMENT_84.md).
M6 추가 검증: [Finder 미리보기·일반 아이콘 정책](verification/m6/INCREMENT_85.md).
M6 추가 검증: [빈 공간 이중 클릭 상위 이동](verification/m6/INCREMENT_86.md).
M6 추가 검증: [탭 스크롤 방향 정책](verification/m6/INCREMENT_87.md).
M6 추가 검증: [네이티브 탭 작업·진행 표시 경계](verification/m6/INCREMENT_88.md).
M6 추가 검증: [현재 폴더 이름 필터](verification/m6/INCREMENT_89.md).
M6 추가 검증: [검색 결과의 상위 폴더 열기](verification/m6/INCREMENT_90.md).
M6 추가 검증: [임시 파일 모음](verification/m6/INCREMENT_91.md).
M6 추가 검증: [Git 마지막 커밋 열](verification/m6/INCREMENT_92.md).
M6 추가 검증: [폴더 간 보기 설정 동기화](verification/m6/INCREMENT_93.md).
M6 추가 검증: [정보 pane](verification/m6/INCREMENT_94.md).
M6 추가 검증: [시스템 저장 공간 설정](verification/m6/INCREMENT_95.md).
M6 추가 검증: [폴더 펼치기](verification/m6/INCREMENT_96.md).
M6 추가 검증: [Finder 휴지통 연결](verification/m6/INCREMENT_97.md).
M6 추가 검증: [새 항목 선택](verification/m6/INCREMENT_98.md).
M6 추가 검증: [동기화 상태 정렬·그룹화·열](verification/m6/INCREMENT_99.md).
M6 추가 검증: [파일 미리보기 메모리 캐시](verification/m6/INCREMENT_100.md).
M6 추가 검증: [최근 파일 전송 실행 취소](verification/m6/INCREMENT_101.md).
M6 추가 검증: [이동 재실행](verification/m6/INCREMENT_102.md).
M6 추가 검증: [템플릿으로 파일 생성](verification/m6/INCREMENT_103.md).
