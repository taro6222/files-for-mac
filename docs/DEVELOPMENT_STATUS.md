# 개발 현황

갱신: 2026-11-14

## 이번 구현 단위

M5 스물일곱 번째 개발 단위로 stdin 기반 ssh-keyscan 후보 수집과 fingerprint 명시 승인 AppKit UI를 구현했다. M3/M4 실기기·앱 번들 검증은 완료 판정을 막는 별도 항목으로 유지한다.

| 영역 | 상태 | 내용 |
|---|---|---|
| 원격 기반 | 완료 | 지정 origin의 초기 LICENSE/이력 보존 |
| 기준 원본 | 완료 | v4.2.9/SHA 고정 |
| 원본 인벤토리 | 진행 | 202 명령 후보·143 설정·33 화면 소스. 전수 동작 검증 아님 |
| 네이티브 앱 | 구현 | AppKit 창·네이티브 탭 그룹·사이드바·홈·상세 목록·경로 |
| 로컬 I/O | 검증 | 배치 열거·숨김 항목·메타데이터·파일 identity·오류 상태 |
| 탐색 상태 | 검증 | 히스토리·선택 복원·외부 rename 대응·오래된 비동기 결과 방지 |
| 파일 목록 | 구현 | 다중 선택·자연 정렬·열 정렬/재배치/크기 저장 |
| 보기 모드 | 구현 중 | 양쪽 pane 상세·그리드·단일열 목록·계층형 컬럼 및 적응형 정책, 작게/보통/크게 프리셋 저장, 선택 identity·스크롤·세션·파일 작업 보존 |
| 편의 기능 | 구현 | 경로 추천·확장자 옵션·공유 즐겨찾기 순서·홈 용량·최근 기록 삭제 |
| 명령 팔레트 | 구현 | 메인 메뉴 자동 인덱싱, 다국어 부분 검색, 문맥별 활성 조건, 단축키 표시, 키보드 실행·취소 |
| 단축키 | 구현 | 실제 keyDown recorder, 사용자 override 저장, 중복·수정키 없음·macOS 예약 조합 차단, 기본값 복원 |
| 툴바 | 구현 | 항목 표시·숨김, 순서 변경, 필수 경로 필드 보호, 좁은 창 overflow, 전체 창 즉시 반영과 재실행 저장 |
| 외형 | 구현 | 시스템 설정·밝게·어둡게 즉시 전환과 저장, 모든 창 반영, macOS sidebar 재질의 대비·투명도 접근성 설정 추종 |
| 폴더별 설정 | 구현 | 표준 경로별 보기 모드·크기 저장, 양쪽 pane 적용, 폴더 설정 우선·해제 시 전역값 복귀, 손상 JSON 복구 |
| 설정 관리 | 구현 | 저장된 폴더별 보기 개수 표시, 전체 초기화, 초기화 즉시 모든 창 반영 |
| 검색 | 검증 | ⌘F 패널, 직접 열거 파일명/Spotlight 콘텐츠 adapter, 실제 인덱스 hit, 범위·종류·숨김·Finder 태그·B/KB/MB/GB 최소·최대 크기·수정 날짜 필터 및 입력 오류 표시, 인덱스 범위 안내, 진행·중단·부분 결과·접근 실패, 결과 열기 |
| 정보·속성 | 구현 중 | ⌘I 패널, 다중 선택 요약, 논리/할당 크기, 날짜, 소유자·그룹·POSIX 권한, UTI, Finder 태그, 볼륨, 접근 상태, SHA-256 진행·취소 |
| 미리보기 | 구현 중 | Space/메뉴 네이티브 QLPreviewPanel, 선택 항목 datasource, 다중 선택 탐색, 패널 종료 시 datasource 해제 |
| Finder 태그 | 구현 중 | 정보 패널 편집, resource-value 읽기·쓰기, 공백·중복 정규화, 제어문자 차단, identity 재검증, 폴더 감시 갱신 |
| 드라이브 | 구현 중 | 장착/해제 알림 갱신, 이름·용량·여유 공간·포맷·내장/로컬/읽기 전용·제거 가능 capability, 홈 사용량·사이드바 탐색, 파일 작업 차단형 안전 추출, Disk Utility 연결 |
| 시스템 열기 | 구현 | 기본 연결 앱, Finder에서 보기, macOS 공유 picker, Terminal에서 위치 열기, 사용자가 선택한 앱/IDE로 열기; URL 기반 전달 |
| 압축 | 구현 중 | ZIP/7z 생성·탐색·안전 추출, RAR 탐색·안전 추출, 링크/특수 항목 거부·변경 재검증, staging/publish/rollback, AppKit UI·중단·항목/바이트 진행률 |
| 클라우드 | 구현 중 | `~/Library/CloudStorage` 공급자 폴더와 iCloud Drive 탐지·사이드바 탐색, ubiquitous resource value 기반 상태 분류, iCloud 지금 다운로드·공간 비우기 메뉴, 일반 File Provider 상태는 unknown·명령 비활성 유지 |
| 원격 연결 | 구현 중 | FTP/FTPS provider, SFTP strict executor·trust 저장소, ssh-keyscan host stdin 전달·후보 parser, SFTP 프로필 전용 fingerprint/key type/host 표시와 명시적 신뢰 UI |
| 테스트 | 통과 | 137개 Swift Testing, keyscan 인자 host 부재·후보 중복/주석/빈 출력, trust 저장, UI 4조합 SFTP 승인 명령·FTP 실제 수용·기존 회귀 검증 |
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

다음 구현은 M5 SFTP identity file 선택·프로필 참조와 실제 목록 연결 UI다. 실제 sshd·FTPS·안전 FTP 서버, SMB·Keychain·클라우드 실환경 검증은 후속 게이트로 유지한다.

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
[클라우드 위치·상태 탐지](verification/m5/INCREMENT_11.md), [iCloud 다운로드·공간 비우기 명령](verification/m5/INCREMENT_12.md), [원격 연결 프로필 기반](verification/m5/INCREMENT_13.md), [원격 프로필 저장·Keychain](verification/m5/INCREMENT_14.md), [원격 연결 관리 UI](verification/m5/INCREMENT_15.md), [SMB 표준 연결 adapter](verification/m5/INCREMENT_16.md), [원격 backend·보안 명령 계획](verification/m5/INCREMENT_17.md), [원격 subprocess 실행·취소](verification/m5/INCREMENT_18.md), [FTP/FTPS 목록 provider](verification/m5/INCREMENT_19.md), [FTP/FTPS 안전 다운로드](verification/m5/INCREMENT_20.md), [FTP/FTPS staging 업로드](verification/m5/INCREMENT_21.md), [localhost FTP 실제 수용 검증](verification/m5/INCREMENT_22.md), [FTP rename capability probe](verification/m5/INCREMENT_23.md), [SFTP strict trust 명령 계약](verification/m5/INCREMENT_24.md), [SFTP private config executor](verification/m5/INCREMENT_25.md), [SFTP host fingerprint 저장소](verification/m5/INCREMENT_26.md), [SFTP host key 승인 UI](verification/m5/INCREMENT_27.md).
