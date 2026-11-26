# 개발 현황

[368단계](verification/m7/INCREMENT_368.md)는 같은 366 프리뷰를 /private/tmp에 읽기 전용 마운트해 실제 앱의 내용물·서명과 Swift 57개·격리 helper 50개·진단 SDK 142개·권한 probe 15개를 통과했다. 정상 detach와 최종 미마운트도 확인했다. 작업 폴더 마운트의 원인은 미확정이며 실제 설치/정식 출시는 미완료다. 4a6c79d의 전체 AppKit 원격 실행은 유지 중이고 로컬 GUI/장시간 시험은 실행하지 않았다.

[367단계](verification/m7/INCREMENT_367.md)는 큰 UI 검증 본문을 세 개의 MainActor 비동기 구간으로 나눴다. 함수 경계/들여쓰기를 되돌리면 기존 소스와 바이트 단위로 같으며 검사 삭제는 없다. Debug 34.13초·Release 16.87초 빌드가 통과했다. 원격 컴파일 시간 개선·전체 UI 수용은 아직 진행 중이며 로컬 GUI/장시간 시험은 실행하지 않았다.

[최신 유니버설 프리뷰와 컴파일러 관찰](verification/m7/INCREMENT_366.md): 제품 0420df1의 DMG 생성·양 CPU 정적 검증과 추출한 ARM payload 검사 57개가 통과했다. 마운트 루트 접근 대기는 정상 해제 후 미완료로 기록했다. 원격 ARM의 실제 자식은 LLVM coroutine 변환에서 계산 중이었으며 빌드 638.620초 후 성공했다. Intel·최신 양 CPU와 전체 출시는 계속 진행 중이다.

[365단계](verification/m7/INCREMENT_365.md)는 7z 목록을 페이지로 조회해 전체 JSON 8MiB 때문에 목록이 실패하는 문제를 수정했다. 이전 helper의 35,000항목 실패를 재현하고 새 번들의 전체 목록·원본 변경/잘못된 페이지 거부, escape로 커진 응답의 분할을 확인했다. Swift 57개·실제 격리 helper 50개·진단 SDK 142개·권한 probe 15개가 통과했다. 프레임 상한은 유지하며 최신 양 CPU·전체 UI·정식 출시는 미완료다. 로컬 GUI/장시간 시험을 재시작하지 않았다.

[364단계](verification/m7/INCREMENT_364.md)는 7z 생성 목록을 나눠 전송해 요청 한 번의 1MiB 때문에 많은 파일 생성이 실패하는 문제를 수정했다. 4,000개 파일의 제품/공식 도구 복원과 잘못된 응답·순서·누락 거부를 포함해 실제 번들 Swift 55개·FD 36개, 진단 SDK 128개·권한 probe 15개가 통과했다. 프레임/메모리 상한과 기존 게시·복구 계약을 유지한다. 최신 양 CPU·전체 UI·정식 출시는 미완료이며 로컬 GUI/장시간 시험을 재시작하지 않았다.

갱신 2026-11-27

## 현재 단계

M7 출시 준비가 진행 중이며, 남은 기능 개발과 검증을 함께 진행한다. [a07c80c 개발 프리뷰](verification/m7/PREVIEW_0.1.0.md)의 Apple Silicon 설치·교체·복원은 통과했다. 348 SDK 포함 후보의 마운트·SDK 실행은 별도 확인했으며 새 후보의 앱 설치/전체 동선 수용은 남아 있다. 정식 서명·공증, Intel과 최소 macOS, 실제 서버, 원본 전체 UI 상태 대조, VoiceOver와 장시간 검증은 [출시 검증 현황](verification/m7/RELEASE_GATES.md)에서 추적한다.

원본 명령 202개, 설정 143개, 화면 33개가 대응표에 분류돼 있으며 구조 감사가 통과했다. 이 수치는 각 항목의 실제 수용 검증률과 별도로 관리한다. 전체 UI 상태 대조와 VoiceOver 동선, 외부 서비스 및 지원 환경별 미검증 항목이 있어 전체 대응 완료 판정은 진행 중이다.

## 최신 검증과 남은 실행

[363단계](verification/m7/INCREMENT_363.md)는 빌드 관리자의 현재 부모 계보를 따라 별도 그룹의 자식도 관찰하도록 보완했다. 실제 다른 세션 자식의 sample과 무관한 생존 프로세스 제외를 포함해 headless 28개가 통과했다. 이전 원격은 ARM 작업 성공·Intel 빌드 20분 제한 실패이며 원인 확정은 진행 중이다. SDK 격리 소스의 양 CPU 실행을 유지했다. 앱/SDK 변경이나 로컬 GUI·장시간 재시작은 없다.

[362단계](verification/m7/INCREMENT_362.md)는 7z helper의 내장 식별자·단일 App Sandbox 권한과 실행 전 정책 검증을 제품에 연결했다. 실제 격리 번들 Swift 54개·FD 25개, 별도 진단 SDK 117개·OS 권한 probe 15개와 fixture 8개가 통과했다. source/네트워크 접근 거부와 전달 FD 동작을 구분했고 기본 push에 패키지 수용을 연결했다. 최신 원격/지원 환경·CPU/프로세스 트리·정식 출시는 미완료다. 로컬 GUI/장시간 시험은 재시작하지 않았다.

[361단계](verification/m7/INCREMENT_361.md)는 원격에서 드러난 빌드 진단의 중복 SIGKILL/EPERM과 보고서 누락을 재현·수정했다. 실제 프로세스 종료/현재 그룹 상태 확인을 포함한 headless 검사 19개가 통과했다. 이전 358 Intel의 Debug·Swift 성공 398개/환경 건너뜀 44개·설치 프리뷰 성공을 확인했지만 ARM 12분 시간 초과로 전체 실행은 실패다. 별도 decoder sandbox 후보는 FD 동작을 확인한 실험이며 제품 반영·최신 원격 수용·정식 출시는 미완료다. 로컬 GUI/장시간 시험은 재시작하지 않았다.

[360단계](verification/m7/INCREMENT_360.md)는 원격 Debug·프리뷰 빌드의 같은 실행을 유지하며 CPU·RSS·스택을 수집하고, 취소 시 소유 프로세스를 회수하는 진단을 연결했다. 짧은 headless 검증 15개와 YAML/기존 제한 시간 확인이 통과했다. 원격 시간 초과의 원인과 수정 후 수용은 미완료이며 앱 소스·SDK는 변경하지 않았다. 358 Intel의 Debug/Swift 시험 통과와 프리뷰 진행을 확인했으나 전체 성공으로 집계하지 않는다. 로컬 GUI/장시간 시험은 재시작하지 않았다.

[359단계](verification/m7/INCREMENT_359.md)는 7z 생성의 Unix 권한 기록 누락을 고치고 파일/폴더의 수정 시각(100ns)·rwx 권한 복원을 연결했다. 실제 번들 Swift/SDK 52개·native 117개, 제한 권한·외부 시각 변경과 복구 위치 보존을 확인했다. 다른 metadata·권한/자원 격리·최신 지원 환경·정식 출시는 미완료다. 원격 빌드의 ARM 12분/Intel 20분 시간 초과는 미해결이며 push의 실행 중 CI 자동 취소를 해제했다. 로컬 GUI/장시간 시험은 재시작하지 않았다.

[358단계](verification/m7/INCREMENT_358.md)는 부모의 독립 메모리 관찰과 초과 helper 종료·회수, 한/영 오류 안내를 연결했다. 새 번들 47개 검사가 통과했고 목록·추출·일반/분할 생성의 원본 보존과 미게시를 확인했다. 표본 관찰은 할당 하드 상한이 아니며 파일/네트워크 권한·CPU/프로세스 트리 격리·메타데이터·최신 지원 환경과 정식 출시는 미완료다. 로컬 GUI/장시간 시험은 재시작하지 않았다.

사용자 요청으로 2026-11-26 18:04 KST에 장시간 시험 앱 6개와 wrapper를 모두 종료했다. [측정 기록과 종료 내역](verification/m7/LONG_RUNS_STOPPED_20261126.md)을 보존했으며 8시간 성공으로 집계하지 않는다. 자동으로 재시작하지 않는다. 355단계는 분할 크기 선택과 생성·복구 기록 화면을 연결했다. 새 UI의 원격 수용과 지원 환경·정식 출시는 진행 중이다.

[7z 생성 입력 FD 공급](verification/m7/INCREMENT_357.md)은 SDK가 계획된 인덱스로 요청하는 입력만 부모가 열어 전달한다. 제품의 생성 요청에서 원본 절대 경로를 제거했고 일반 생성도 입력 폴더 내부 출력은 임시 파일 생성 전에 거부한다. 실제 번들 검사 45개·native 경계 114개와 Debug/Release·서명이 통과했다. helper 파일/네트워크 권한·자원 격리, 메타데이터 복원·최신 원격 수용·정식 출시는 미완료다. 로컬 GUI/장시간 시험은 실행하지 않았다.

[355 소스 원격 UI 수용](verification/m7/remote-355-ui-receipt-356.json)은 ARM·Intel × 한/영 × 두 테마의 8개 조합 각각 UI 332개·경계 18개가 모두 통과했고 전체 CI도 성공했다. 실제 물리 입력은 미수용이며 최신 FD 브로커 소스의 원격 수용과 정식 출시를 대신하지 않는다. [356 후속 URL 경계](verification/m7/INCREMENT_356.md)는 인코딩된 NUL 거부와 합법적인 %00 파일명을 구분해 새 번들 42개 검사를 통과했다.

[7z 읽기 원본의 부모 FD 브로커](verification/m7/INCREMENT_356.md)는 탐색·추출의 원본과 각 분할 볼륨을 부모가 열어 SCM_RIGHTS로 전달한다. 디코더는 해당 원본 경로를 다시 열지 않고 검증한 읽기 전용 FD를 소유한다. 실제 번들 검사 42개·native 경계 107개와 Debug/Release·서명이 통과했다. 생성 입력의 FD 전달·SDK 권한/자원 격리·메타데이터 복원·최신 원격 수용·정식 출시는 남아 있다. 로컬 GUI/장시간 시험은 실행하지 않았다.

[분할 생성 화면과 복구 기록](verification/m7/INCREMENT_355.md)은 원본 크기 선택·포맷 전환·설정 저장/가져오기를 실제 분할 생성 API에 연결한다. 앱 메뉴와 정상 시작에서 중단 기록을 찾고, 확인 가능한 작업만 사용자의 선택/확인 뒤 되돌린다. 실제 번들 검사 40개와 Debug/Release·서명이 통과했으며 새 UI 기대 332개는 원격 수용 대기다. 로컬 GUI/장시간 시험은 실행하지 않으며 새 원격 UI·지원 환경·정식 출시는 미완료다.

[분할 7z 생성과 재시작 복구](verification/m7/INCREMENT_354.md)는 전체 임시 아카이브 없이 위치 지정 출력 스트림을 part로 나누고, private 저널·identity/해시·게시 의도와 충돌/취소 rollback을 구현했다. 생성·복구 API의 headless 검증을 마쳤으며 생성 화면의 분할 크기 선택·복구 안내 연결과 최신 원격/지원 환경·정식 출시는 미완료다. 로컬 GUI/장시간 시험은 재시작하지 않았다.

[분할 7z 볼륨 탐색·추출](verification/m7/INCREMENT_353.md)은 전체 병합 복사본 없이 열린 FD들의 seekable 연결 스트림을 SDK에 제공한다. 어느 part에서든 목록/암호 추출, 일괄 중복 제거와 child 이름을 연결했고 누락·잘림·교체·링크·후속 무관 볼륨을 거부한다. 실제 번들 helper를 사용한 검사 34개·native 경계 86개와 Debug/Release·서명 검증이 통과했다. 분할 생성·게시 저널/재기동 복구와 새 원격 UI·지원 환경·정식 출시는 미완료다. 로컬 GUI/장시간 시험은 재시작하지 않았다.

[7z 고급 생성 옵션과 설정 복원](verification/m7/INCREMENT_352.md)은 사전·워드·CPU 요청과 추정 메모리를 생성 화면/SDK에 연결하고 형식·옵션 저장/가져오기를 구현했다. SDK·번들 검사 30개, native 경계 71개와 Debug/Release·서명 검증이 통과했다. 세 사전의 실제 출력 속성과 원문 복원을 확인했다. 이전 350 ARM의 네 조합 UI 각각 324개/경계 18개가 모두 true임을 원문에서 확인했으나 전체 CI는 개수 단언/Intel 파일 작업 오류로 실패다. 새 옵션 UI·분할·실제 자원 사용·지원 환경·정식 출시는 미완료이며 로컬 GUI/장시간 시험은 재시작하지 않았다.

[7z 암호 생성과 생성 화면 연결](verification/m7/INCREMENT_351.md)은 검증된 SDK로 여섯 압축 수준·Unicode 암호·선택적 파일 이름 암호화를 생성 UI에 연결했다. 원본/출력 identity 검증, 충돌 시 덮어쓰기 거부와 취소 정리를 유지한다. native SDK/번들 검사 27개와 Debug/Release·번들 서명 검증이 통과했다. 실제 공식 7-Zip으로 여섯 생성 결과를 복원했다. 새 UI 검사는 원격 수용 대기이며 로컬 GUI·장시간 시험 앱을 다시 실행하지 않았다. 세부 옵션/분할·메타데이터·자원 격리·정식 출시는 미완료다.

[7z 기존 폴더 게시와 암호 UI 연결](verification/m7/INCREMENT_350.md)은 검증된 SDK 선택·헤더 암호 목록 열기·개별/일괄 추출과 here/smart/child 배치를 연결했다. 부분 게시 충돌/취소 rollback과 변경 항목 보존, child 이름 충돌 보존도 구현했다. 로컬 SDK 검사 23개·Core 성공 400개·환경 건너뜀 19개와 Debug/Release가 통과했다. 새 UI 검사 6개는 원격 실행 대기이며 제품 UI 수용 완료로 표시하지 않는다. 사용자 Mac에서 장시간 시험이나 GUI 반복 시험을 재시작하지 않았다. 생성/세부 옵션/분할·메타데이터·자원 격리·정식 배포는 남아 있다.

| 항목 | 확인한 결과 | 남은 실행 |
|---|---|---|
| 설치·업데이트 | 새 a07c80c 유니버설 프리뷰의 macOS 27.2.1 arm64 격리 설치·교체·복원. 이전 프리뷰의 Sonoma 14.8.7·실제 업데이트 메뉴 조회는 별도 기록 | 서명·공증된 정식 배포본의 다운로드·최초 실행·버전 교체 |
| SMB | 파일 시각, 이동·실행 취소, 게시 후 세션 재연결과 기록 중 단절 시 원본 보호·[서버 권한 회수 후 기존 대상 복구](verification/m7/INCREMENT_290.md) | 장기 단절 및 외부 서버 검증 |
| 원격 전체 AppKit | `05dd05d` 두 CPU 작업 성공: 각각 네 조합 전체 303개/경계 18개. `cf63dcf` ARM 네 조합 318개/18개 성공. 3e5c88f Spotlight native 복구 단계 두 CPU 성공, 전체 작업은 확인 시점 진행 중 | 최신 소스 두 CPU 수용. Spotlight 미마운트 정리 수정의 원격 재수용 대기·774083b Intel 빌드 20분 제한·간헐 Git 초기 조회 지연 조사 |
| Xcode 진입점 | `55c1bee`의 Apple Silicon·Intel Xcode 빌드 성공. 전체 AppKit·설치 수용은 별도 진행 | 정식 서명·배포된 산출물의 수용 검증 |
| 장시간 | `5284cb3` 8시간·9,525사이클 종료. 물리 메모리 초기/마지막 60표본 중앙값 52→160MiB로 안정성 미수용. [새 탭 구현의 단기 진단](verification/m7/INCREMENT_330.md)은 컨텍스트 개수 유지 | 최신 소스 8시간 종료 및 물리 메모리 안정성 판정 |

실행별 증거와 정확한 제한은 [설치 프리뷰](verification/m7/INCREMENT_280.md), [SMB 기록 중 단절](verification/m7/INCREMENT_277.md), [서버 권한 회수](verification/m7/INCREMENT_285.md), [Intel UI 진단](verification/m7/INCREMENT_282.md), [Xcode 연결](verification/m7/INCREMENT_284.md), [8시간 시험](verification/m7/INCREMENT_283.md)에 기록했다.

## 이번 구현 단위

[독립 압축 구현 왕복](verification/m7/INCREMENT_344.md)은 공식 7-Zip 26.06을 해시로 고정하고 앱 AES ZIP의 ASCII 양방향·Unicode 복호화와 틀린 암호를 확인했다. 참조 활성화 Core 성공 377개·환경 건너뜀 19개, 호환성 조건 15개·7z 옵션 조건 9개·획득 보호 검사 5개가 통과했다. 7z 고급 제품 연결은 미완료이며 두 CPU 필수 CI와 SDK 연결 계약을 추가했다. 기존 ARM 암호 UI 318개/경계 18개와 Spotlight native 두 CPU 성공도 확인했다. 최신 원격/지원 환경·실제 입력·정식 출시는 계속 진행 중이다.

[Spotlight 미마운트 정리](verification/m7/INCREMENT_343.md)는 소유 이미지 연결만 남은 실제 실패 상태를 재현하고 UUID·컨테이너·물리 저장소 연결을 확인해 처리한다. 읽기 전용 최종 검사와 외부 데이터 보존을 유지했다. 소유권 검사 23개·실제 미마운트 정리·합성 추가 데이터 보존·EBUSY 재시도가 통과했고 시험 이미지 4개가 정리됐다. 두 CPU CI 회귀를 추가했으며 원격 원인 확정/재수용은 미완료다. 앱 소스는 유지해 빌드·Core/UI를 반복하지 않았다. M7 정식 출시 게이트는 열린 상태다.

[ZIP 암호 생성·추출 UI](verification/m7/INCREMENT_342.md)는 생성 옵션·암호 표시·입력 정리와 개별/혼합 일괄 추출의 암호 시트를 연결했다. 틀린 암호 재시도·시트/작업 취소·후속 손상 파일 보호를 확인하고 ZIP password capability를 활성화했다. Swift 성공 376개·환경 건너뜀 19개, 최종 네 조합 전체 UI 각각 318개/경계 18개·Debug/Release가 통과했다. 7z/RAR 암호·전체 원본 옵션·물리 입력·최신 원격/장시간·정식 서명/공증은 미완료다.

[ZIP 암호 서비스](verification/m7/INCREMENT_341.md)는 AES-256 생성·복호화와 암호화 항목 판별을 구현했다. 저장/최고 수준 왕복·틀린/누락 암호·암호문 변조·취소·기존 파일 보호를 확인했다. Swift 성공 376개·환경 건너뜀 19개, 네 조합 기존 UI 각각 312개/경계 18개·Debug/Release가 통과했다. 암호 입력 UI와 capability 광고는 미완료이며 7z/RAR 암호·독립 구현 호환성·최신 원격/장시간·정식 서명/공증도 남아 있다.

[압축 수준과 선택 복원](verification/m7/INCREMENT_340.md)은 여섯 수준을 ZIP·7z 엔진에 연결하고 선택 저장·재개방·재기동·설정 가져오기를 구현했다. 두 포맷의 총 12회 생성·추출과 저장/압축 결과를 확인했다. Swift 성공 372개·환경 건너뜀 19개, 네 조합 전체 UI 각각 312개/경계 18개·Debug/Release·parity가 통과했다. 원본 옵션 세부 대응표에 암호·분할 등 미구현을 남겼으며 최신 원격/장시간·실제 입력·정식 서명/공증은 미완료다.

[압축 생성 형식 선택](verification/m7/INCREMENT_339.md)은 실제 저장 창에 ZIP·7z 팝업을 추가하고 선택한 형식과 확장자를 연결한다. 한글·복수 확장자·명시적 확장자·빈 이름을 보존하는 동작을 확인했다. 네 조합 전체 UI 각각 310개/경계 18개·Debug/Release·parity가 통과했다. 이전 고정 소스의 두 CPU 성공 보고서도 확인했다. 최신 원격/장시간·전체 원본 UI 대조·실제 입력/VoiceOver·정식 서명/공증은 미완료다.

[압축 저장 기본 이름](verification/m7/INCREMENT_337.md)을 원본과 맞춰 단일 항목의 전체 이름과 여러 항목의 부모 폴더 이름을 보존한다. 실제 NSSavePanel 객체로 TXT·한글·점/복수 확장자·ZIP·여러 항목·루트 대체값을 확인했다. 네 조합 전체 UI 각각 306개/경계 18개·Debug/Release가 통과했다. 기존 a07c80c 프리뷰와 새 변경을 구분하며 원격/최신 후보·Git snapshot 지연·장시간·실제 입력·정식 서명/공증 수용은 미완료다.

[새 유니버설 개발 프리뷰](verification/m7/INCREMENT_336.md)는 소스 a07c80c로 고정해 ARM·Intel 슬라이스와 DMG를 만들고 macOS 27.2.1 arm64의 격리 설치·손상본 거부·교체·복원 및 설정/세션 보존을 통과했다. 공유 캐시의 Launch Services 20회 첫 창 p95는 278ms였다. Windows 압축 창의 다섯 입력·취소 상태와 원본 manifest 보존도 실제 수집에서 통과했다. Intel/최소 OS 새 이미지 설치·Mac 대응 상태·실제 입력·장시간·정식 서명/공증 수용은 미완료다.

[원격 진단 보존](verification/m7/INCREMENT_335.md)은 세션 비교 JSON·Git 시간 초과 스택의 업로드 누락을 보완했다. YAML 파싱·기대 파일 11개 매칭과 fixture 제외가 통과했다. cc0031b ARM의 네 조합 전체 UI 각각 303개/경계 18개가 실제 보고서에서 통과했으며 상세 비교 JSON은 당시 보존되지 않아 숫자를 추정하지 않는다. 앱 소스는 유지하고 기존 검증을 계속한다. Intel 지연·새 경로 원격 수용·Windows 입력/취소·장시간·정식 출시 게이트는 미완료다.

[Intel 초기 Git 창 진단](verification/m7/INCREMENT_334.md)은 10초 기준을 유지하고 조회 단계·상태·실행 여부와 실패 전 소유 프로세스 스택을 기록한다. 원인 해결로 판정하지 않는다. Windows 압축 창은 실제 표시를 확인했고 창 밖 탭 닫기와 Cancel의 ID 충돌을 대화상자 범위 검사·클릭으로 보완했다. 네 조합 전체 UI 각각 303개/경계 18개·Debug·수집 보호 시험 19개가 통과했다. Intel 재수용·Windows 입력/취소·장시간·실제 입력/지원 환경·정식 서명/공증은 미완료다.

[화면 보정 후 세션 검증](verification/m7/INCREMENT_333.md)은 큰 저장 창에서 기존 실패를 재현해 창 경계 보정과 0.1pt 분할 배치 차이를 분리했다. 패널·탭·이력 상태는 유지하고 실제 비율 위치 1pt 상한·정확한 프레임 검사를 적용한다. 네 조합 전체 UI 각각 303개/경계 18개·Debug·수집 보호 시험 16개가 통과했다. Windows 압축 수집의 실제 명령 이름도 보완했다. DEBUG 밖 앱 소스는 유지했으며 새 원격 수용·실제 압축 화면 대조·8시간 안정성·정식 배포 게이트는 미완료다.

[새 탭 이중 패널 기본값](verification/m7/INCREMENT_331.md)은 ⌘T에만 적용되던 설정을 폴더·시작 추가 탭에도 적용하고, 일반 새 창·명시적 복제/복원 상태와 배경/선택 정책을 유지한다. 실제 생성기 검증에서 비동기 분할 복원을 기다린 후 동일 조건을 확인했다. Swift 성공 370개·환경 건너뜀 19개, 네 조합 전체 UI 각각 302개/경계 18개·Debug/Release가 통과했다. 개발 현황의 오래된 원격·8시간 상태도 기존 실행 증거에 맞췄다. 최신 소스 원격/8시간·물리 수용·정식 서명/공증 등 M7 게이트는 미완료다.

[초기 목록의 중복 재조회 줄이기](verification/m7/INCREMENT_325.md)는 열거 전 배경에서 경로·장치·이력 UUID·이벤트 ID를 준비하고 등록 시 재검증한다. 유효한 내부 이력은 변경을 재생하며, 이력 불가·불일치·기존 factory는 재조회를 유지한다. 감시 등록·중지는 GCD로 옮겼고 이력 완료 표식은 무시하며 유실·루트 변경은 재조회한다. Swift 성공 361개·환경 건너뜀 19개, 실제 볼륨 시험 8개·제한 실행기 10개·네 조합 파일 작업 UI 각각 85개·전체 UI 각각 283개와 Debug·Release 빌드가 통과했다. Intel 원격 재수용과 메모리·최신 8시간·정식 배포 수용은 미완료다.

[탭 메모리 SDK·런타임 대조](verification/m7/INCREMENT_324.md)는 동일 SDK 26.2 ARM 바이너리를 macOS 15.8.2·27.2.1에서 세 차례씩 측정했다. 탭 컨텍스트는 각각 71→211→1,651개·413→1,113→8,313개로 증가했다. 같은 macOS 27에서 SDK 27.2 빌드와 증가가 같아 SDK 26 빌드만으로 해결되지 않았다. 창 재사용·공개 탭 그룹 유지도 증가가 남아 제품에 적용하지 않았다. Intel 첫 힙 수집은 도구 시간 초과로 실패했다. 측정기의 20초 기준을 유지하고 시간 초과 스택·소유 자식 종료를 검증했으며 짧은 수동 진단 옵션을 추가했다. 제품 메모리 해결·최신 소스 8시간·정식 서명·공증 수용은 미완료다.

[앱 코드 없는 네이티브 탭 메모리 재현](verification/m7/INCREMENT_323.md)은 AppKit만 사용하는 별도 실행 파일로 창·탭을 세 차례씩 비교했다. 5·40·400사이클에서 독립 창 컨텍스트는 104개 유지, 탭은 413→1,113→8,313개 증가가 반복됐으며 기준 창 한 개·보조 창 400개 해제를 확인했다. 제품 코드는 변경하지 않았고 안정성 통과로 집계하지 않는다. SDK/런타임 차이를 비교할 두 CPU 수동 진단과 바이너리/SDK 근거 보존을 추가했다. `28f8020` 원격 전체 CI는 성공했으며 최신 소스 수용·메모리 해결·최신 소스 8시간·서명·공증은 남아 있다.

[이동 선택 전체 데이터 집계](verification/m7/INCREMENT_322.md)는 교차 볼륨 원본의 기존 검증 스냅샷을 미리 준비해 재사용하고 staging 합계를 진행 창·최종 보고서·저널에 연결한다. 같은 볼륨 이름 변경은 0바이트이며 데이터 100%와 작업 성공을 구분한다. 준비 후 원본 변경·취소·게시 충돌·Undo·늦은 UI 알림을 검사했다. Swift 성공 356개·환경 건너뜀 19개, 실제 볼륨 시험 8개·제한 실행기 10개·네 조합 파일 작업 UI 각각 85개·전체 UI 각각 283개와 Debug·Release 빌드가 통과했다. 최신 원격·메모리 안정성·최신 소스 8시간·정식 서명·공증 수용은 남아 있다.

[ACL 계정 조회·저장 수명 관리](verification/m7/INCREMENT_321.md)는 규칙 확인 중 저장을 차단하고 시트 종료 시 목록·규칙 작업을 취소하며 늦은 응답을 배제한다. 수동 편집 상태의 저장 차단·응답 후 실제 ACL 적용·닫힌 시트 응답 무시를 네 조합에서 확인했다. Swift 성공 349개·환경 건너뜀 19개, 제한 실행기 10개·파일 작업 UI 각각 83개·전체 UI 각각 283개와 Debug·Release 빌드가 통과했다. 기존 계정 조회 5초 기준은 유지하며 새 단계 진단을 남긴다. Intel 기존 실패 원인 해결과 원격 전체 수용·M7 출시는 미완료다.

[겹치는 폴더 Undo 검증 후 통합](verification/m7/INCREMENT_320.md)은 자체 게시한 하위 결과만 예상 트리에 합쳐 내용·메타데이터·열린 디렉터리 identity가 맞을 때 한 기록으로 묶는다. 하위 identity 경계를 유지하고 외부 변경·근거 누락·오래된 불명 기록은 보존한다. 이전 같은 이름 폴더의 부분 복원 회귀를 전체 복원으로 강화했다. Swift 성공 348개·환경 건너뜀 19개, 실제 볼륨 시험 8개·제한 실행기 10개·네 조합 파일 작업 UI 각각 83개·전체 UI 각각 283개와 Debug·Release 빌드가 통과했다. 새 원격·지원 환경 전체 수용은 계속 진행한다.

[병합 선택 전체 데이터 집계](verification/m7/INCREMENT_319.md)는 여러 원본·하위 작업의 staging 데이터를 합산하고 같은 이름 폴더의 순차 병합에서 예정량을 갱신한다. 준비 원본 재검증·목적지 identity·충돌 보존을 유지한다. Swift 성공 343개·건너뜀 18개, 실제 볼륨 7개·제한 실행기 10개·네 조합 UI 각각 82개·283개와 Debug·Release 빌드를 통과했다. 겹치는 상위/하위 Undo는 하위 삭제 후 폴더 날짜 불일치로 부분 복원이 남아 있어 F13 전체 수용은 미완료다.

[여러 원본 복사 데이터 합계](verification/m7/INCREMENT_318.md)는 기존 무결성 스냅샷을 재사용해 선택 전체의 논리 staging 바이트·예정량을 합산하고 건너뛴 충돌·불명 크기·늦은 알림을 처리한다. 최종 보고서와 기존 저널 읽기를 검증했으며 데이터 100%를 작업 성공률로 표시하지 않는다. Swift 성공 334개·건너뜀 18개, 실제 볼륨 7개·제한 실행기 10개·네 조합 파일 작업 UI 각각 82개·전체 UI 각각 283개와 Debug·Release 빌드를 통과했다. 이동·병합의 전체 선택 집계와 원격·장시간·정식 배포 수용은 남아 있다.

[Git 복제 시간 초과 상태 보존](verification/m7/INCREMENT_317.md)은 기존 20초 대기 기준을 유지하며 실행 상태·문구·소유 프로세스 스택을 보존하고 취소 종료를 기다린다. 실패 후 없는 대상에 파일을 쓰던 검증 흐름을 차단했다. gate 자식의 실제 취소·staging 정리는 네 조합에서 확인했고 파일 작업 UI 각각 80개·전체 UI 각각 283개가 통과했다. 새 진단 코드는 Release에서 제외된다. Intel 지연 원인 해결과 원격 재수용은 미완료다.

[폴더 병합 실제 바이트 진행](verification/m7/INCREMENT_316.md)은 누락 항목의 네이티브 복사 콜백을 진행 창까지 전달하고 이전 작업·단계·바이트의 지연 알림을 차단한다. 하위 복사 실패를 상위 결과에 전파하며 원본 재검증·비덮어쓰기 게시·Undo를 유지한다. Swift 성공 329개·건너뜀 18개, 실제 볼륨 7개·제한 실행기 10개, 네 조합 파일 작업 UI 각각 80개·전체 UI 각각 283개와 Debug·Release 빌드를 통과했다. 전체 선택 바이트 합계·장시간·Intel 재수용·정식 배포 수용은 남아 있다.

[네이티브 탭 잔여 증가 분리](verification/m7/INCREMENT_315.md)는 명시적 탭 분리와 최초 탭 막대 표시 요청이 컨텍스트 5개/사이클 증가를 줄이지 못함을 확인했다. 독립 창 대조의 중간 힙은 유지됐으나 최종 로딩 대기 실패를 보존한다. 제품 수정·메모리 안정성 통과로 집계하지 않는다. `740ebf4`의 두 CPU Swift 시험·두 Xcode 빌드는 성공했고 전체 CI는 진행 중이다.

[저장 Finder 태그 우선 읽기](verification/m7/INCREMENT_314.md): 목록·로컬 검색·속성·편집 스냅샷에 저장 속성 읽기를 연결했다. Swift 성공 324개·건너뜀 18개, 실제 볼륨 7개·제한 실행기 10개, 네 조합 파일 작업 UI 각각 79개·전체 UI 각각 283개와 Debug·Release 빌드는 통과했다. 두 CPU 원격 수용은 진행 중이다.

[최근 기록 행 재사용·메모리 대조](verification/m7/INCREMENT_313.md): 최근 위치 스택의 관찰 객체 보유를 추적하고 위치·파일 행을 재사용한다. 같은 최적화 QA의 5→40사이클에서 컨텍스트 증가가 490→175개로 줄었지만 계속 증가해 장시간 게이트는 미통과다. 메뉴 URL·논리 초점·행 재사용을 포함한 네 조합 각각 파일 작업 UI 78개·전체 UI 283개가 통과했다. 당시 ARM 태그 CI 실패는 Increment 314 수정 후 두 CPU Swift 시험에서 재검증을 통과했다. 전체 원격 수용은 별도로 추적한다.

[교차 볼륨 이동의 바이트 표시](verification/m7/INCREMENT_312.md): 네이티브 콜백을 이동 창에 연결하고 기존 검증·게시·원본 재검증 후 삭제·Undo를 유지했다. Swift 성공 319개·건너뜀 18개, 실제 볼륨 7개, 네 조합 파일 작업 UI 각각 79개 통과. 이전 `86be2b0` 8시간은 정상 종료했지만 시간대별 물리 메모리 중앙값 증가로 게이트 미통과다.

[복사 중 논리 바이트](verification/m7/INCREMENT_311.md): 현재 원본 파일·폴더의 바이트·예정량·백분율·평균 논리 속도를 네이티브 콜백으로 표시한다. 원본 보호·비공개 staging·해시 검증·게시·Undo를 유지한다. Swift 성공 315개·건너뜀 18개, 실제 볼륨 7개, 제한 실행기 10개, 네 조합 각각 파일 작업 UI 79개·전체 UI 283개 및 수신 계약 53개를 통과했다. 새 소스 원격 수용은 진행 중이다. 이동·병합·여러 원본 전체의 바이트 가중 진행률은 남아 있다. `4a19117` 최적화 CI는 ARM 통과·Intel 미달로 전체 실패다.

[최적화 표본·원격 실패 대조](verification/m7/INCREMENT_310.md): `4a19117` 로컬 1만 항목 20회 p95가 첫 표시 53ms·모델 열거 445ms로 기준을 통과했고 300초 유휴 측정도 정상 종료했다. 이전 입력 수정본의 Intel 자동 폴더 크기 실패는 원본 진단과 해시를 보존했으며 전체 CI 성공으로 처리하지 않는다. 인증서·공증 프로필은 사용자 준비 중이다.

[태그 보존 메타데이터 병렬화](verification/m7/INCREMENT_309.md): File Provider 조회 비용을 실제 스택·API 대조로 확인했다. 태그 prefetch와 모든 필드를 유지하며 나머지 조회를 묶음당 네 작업으로 제한한다. Swift 성공 307개·건너뜀 18개, 제한 실행기 10개, 네 조합 각각 파일 작업 UI 78개·전체 UI 283개를 통과했다. 최적화 20회 p95 판정과 최신 소스 장시간 검증은 진행 중이다.

[일괄 이름 변경 입력 안내](verification/m7/INCREMENT_308.md): 빈 입력으로 창이 닫히던 동작을 고치고 번호·금지 문자·정규식 오류를 즉시 안내한다. 유효할 때만 미리보기가 가능하다. 로컬 네 조합 각각 파일 작업 UI 78개·전체 UI 283개가 통과했다. Windows 실제 전송·취소 및 이름 입력·취소 원본도 확보했다. 새 입력 구성요소의 원격 수용은 진행 중이며 이전 `5284cb3`의 네 CI 작업은 모두 성공했다.

[동일 앱 소스의 재기동 복원 수용](verification/m7/INCREMENT_304.md): `5284cb3`의 두 CPU 각각 강제 종료 후 재기동 14개·위치 기록 후 복원 19개, 수신 계약 53개·제한 실행기 9개를 통과했다. ARM 전체 AppKit 네 조합 각각 283개도 확인했다. Intel 전체 UI·설치 최종 결과는 진행 중이다.

[두 CPU 최적화 성능 기준](verification/m7/INCREMENT_307.md): 실제 최적화 QA의 10,000항목 20개 프로세스 측정을 두 CPU CI에 연결했다. 원본 표본의 p95·소스·CPU·요약을 대조하는 보호 시험 6개를 통과했다. 실제 원격 성능 결과는 진행 중이다. `396866c`의 두 CPU 프리뷰 설치·기동은 성공했으며 전체 workflow는 별도 ARM Xcode 취소로 실패였다.

[원본 입력 초점·일괄 이름 변경](verification/m7/INCREMENT_306.md): Windows 전송 수집이 목적지 주소 입력에서 실패해 실제 화면·로그를 보존했다. 입력 초점 확인과 행 선택 탐색을 추가하고 일괄 이름 변경의 빈 이름·오류·정상·취소 수집을 구현했다. 로컬 보호 10개 통과, 수정 후 Windows 실행은 진행 중이다.

[최신 후보 장시간·Windows 전송 상태](verification/m7/INCREMENT_305.md): `5284cb3`의 별도 8시간 시험과 두 CPU 전체 AppKit·Xcode 검증을 시작했다. Windows 원본의 전송 중·취소 화면 수집을 추가하고 보호 시험 5개를 통과했다. 실제 Windows 결과와 장시간 종료 판정은 진행 중이다.

[이동 위치 기록 후 실제 강제 종료·복원](verification/m7/INCREMENT_304.md): 서로 다른 앱 PID에서 수신본 복원·내용 보존·기록 불변 검사를 네 조합 각각 19개 통과했다. 위치 미기록 회귀 14개와 기존 계약 53개도 통과했다.

[메타데이터 조회 실행 분리](verification/m7/INCREMENT_303.md): 폴더 크기·클라우드·볼륨 조회를 Swift 협력 실행기 밖으로 옮기고 취소 대기를 먼저 반환한다. URL 생성 시 중복 유형 조회를 피하면서 identity·메타데이터 신선도를 유지한다. 원격 실제 요청 완료와 창 닫기 취소를 대조하고 시험 이미지 busy 재시도는 소유권을 매번 재검증한다. Swift 성공 304개·건너뜀 18개, 제한 실행기 9개, 전체 UI 네 조합 각각 283개와 파일 작업 UI 각각 79개, 실제 EBUSY 정리를 통과했다. Intel 후속 결과와 성능 목표 판정은 남아 있다.

[수신 보관본의 보관소 복원](verification/m7/INCREMENT_302.md): 부모·보관본 identity와 전체 트리 fingerprint, 원본 receipt를 다시 검사한 뒤 원래 보관소로 덮어쓰지 않고 복원한다. 취소·작업 센터·목록 갱신을 연결하고 원본 정리 기록은 불변으로 보존한다. Swift 성공 297개·건너뜀 18개, 수신·복원 계약 네 조합 각각 53개와 전체 AppKit 각각 283개를 통과했다. 위치 기록 후 실제 SIGKILL 복원과 설치·접근성·정식 배포 수용은 남아 있다.

[실제 강제 종료 후 수신 정리 기록 확인](verification/m7/INCREMENT_301.md): 실제 휴지통 이동 뒤 위치 저장 전 FilesMac을 SIGKILL하고, 다른 PID의 FilesMac이 기록·원본·복사본과 위치 미확인 UI를 확인했다. 네 조합 각각 14개와 기존 수신 계약 45개, Swift 성공 287개·건너뜀 18개를 통과했다. 위치가 없어도 수신 파일명을 표시하도록 새 기록을 보완했다. 다른 저장 단계와 명시적 복원·재시도·접근성은 남아 있다.

[수신 정리 기록 재조회](verification/m7/INCREMENT_300.md): 새 기록의 폴더 identity와 수신 receipt를 대조해 원래 위치·이동 위치·미확인·이전 형식·손상을 구분하는 조회 화면을 추가했다. 관련 코어 6개를 포함한 Swift 성공 287개·건너뜀 18개, 네이티브 계약 네 조합 각각 45개와 전체 AppKit 각각 283개를 통과했다. 별도 프로세스 재기동과 중단 작업의 명시적 복원·재시도, 실제 접근성 수용은 남아 있다.

[독립 APFS Spotlight 검증](verification/m7/INCREMENT_299.md): 호스트 색인 설정을 바꾸지 않고 실제 원본 콘텐츠 검색·범위 검사 4개와 전체 AppKit 네 조합 각각 283개를 통과했다. 정리 보호 시험 10개와 실제 읽기 전용 재검사·이미지 정리도 통과했다. 새 소스의 두 CPU 원격 실행은 후속 판정한다. 기존 `8a06e92`의 Xcode는 두 CPU 모두 성공했다.

[수신 보관본 정리](verification/m7/INCREMENT_298.md): 복사 기록과 원본·대상 재검증, 휴지통 이동 후 검사·덮어쓰지 않는 복원, 작업 센터·취소·결과 보기를 연결했다. Swift 성공 281개·건너뜀 18개, 수신·정리 계약 네 조합 각각 40개를 통과했다. F17 실제 수용과 미완료 정리의 재시작 후속 처리는 진행 중이다.

[동기 목록 조회 실행 분리](verification/m7/INCREMENT_297.md): Swift 실행기 밖에서 파일 시스템 응답을 기다리고, 제한 실행기에서 대기·취소를 검증했다. 전체 UI는 검사별 진행 기록과 완료 대조를 추가했으며 로컬 네 조합 각각 283개를 통과했다. Intel의 같은 소스 전체 실행은 후속 판정한다.

[재시작 후 수신 파일 복구 화면](verification/m7/INCREMENT_296.md): 보관 작업 목록과 재검증을 거친 복사 재개를 추가했다. 손상 기록은 보존하고 자동 복사를 막는다. 관련 55개 시험과 네이티브 계약 28개 통과. 실제 메뉴·폴더 선택·재기동·접근성 수용과 보관소 정리는 진행 중이다.

[파일 약속 수신 UI 연결](verification/m7/INCREMENT_295.md): 모든 파일 보기에 외부 수신, 독립 보관소, 충돌 정책·복사·단일 Undo를 연결했다. 51개 관련 시험과 AppKit 계약 24개 통과. 실제 SDK 드래그 수용·재시작 복구 화면·보관소 정리는 진행 중이다. 인증서와 공증 프로필은 사용자 준비 중이다.

정보 패널의 탭을 유지한 채 긴 파일 속성과 미리보기 본문을 세로로 스크롤할 수 있다. [정보 패널 스크롤](verification/m7/INCREMENT_222.md)

검색 창에서 최소·최대 크기 입력란의 표시 너비를 확보했다. [검색 크기 필터](verification/m7/INCREMENT_215.md)

SMB가 0바이트 리소스 포크를 보고하는 경우 전송 비교에서 없는 리소스 포크와 같은 내용으로 처리한다. [SMB 진단과 수정](verification/m7/INCREMENT_211.md)

분할 패널에서 같은 폴더를 새로 읽어도 편집 중인 경로가 유지된다. [경로 입력 보호](verification/m7/INCREMENT_209.md)

컬럼 보기에서 각 열의 경계를 드래그해 너비를 조절할 수 있다. [컬럼 너비 조절](verification/m7/INCREMENT_205.md)

컬럼 보기에서 좌우 방향키로 초점을 옮기면 작업 선택도 해당 컬럼에 맞춰 갱신된다. [컬럼 키보드 탐색](verification/m7/INCREMENT_204.md)

분할 화면의 상세 보기에서 첫 파일 행이 헤더 아래에 표시되도록 수정했다. [분할 보기 검증](verification/m7/INCREMENT_203.md)

컬럼 보기에서 현재 폴더의 상위 경로를 표시하고 왼쪽 방향키로 상위 폴더에 이동한다. [상위 경로 컬럼](verification/m7/INCREMENT_202.md)

상세 보기의 Finder 태그 열을 기본으로 표시하고 분할 패널에도 태그 표시와 정렬을 적용한다. [상세 보기 태그 열](verification/m7/INCREMENT_198.md)

홈의 파일 태그 위젯에서 Spotlight에 색인된 항목을 Finder 태그별로 보고 연다. [파일 태그 위젯](verification/m7/INCREMENT_196.md)

상세 보기에서 전체 폴더 크기 계산을 꺼도 필요한 폴더의 크기만 조회할 수 있다. [개별 폴더 크기](verification/m7/INCREMENT_193.md)

홈에서 앱으로 연 최근 파일을 다시 열고 최근 위치와 별도로 관리한다. [최근 파일](verification/m7/INCREMENT_192.md)

홈의 빠른 접근과 드라이브를 창 너비에 맞춘 카드로 표시하고 방향키로 탐색한다. [홈 카드](verification/m7/INCREMENT_190.md)

파일 메뉴의 작업 센터에서 복사·이동·폴더 병합 상태와 열려 있는 결과를 확인하고 작업을 취소한다. [파일 작업 센터](verification/m7/INCREMENT_188.md)

홈에서 네트워크 위치의 표시·펼침을 드라이브와 별도로 제어한다. [홈 네트워크 위젯](verification/m7/INCREMENT_184.md)

고정 Windows 원본을 CI에서 설치·실행하고 홈 화면을 캡처하는 작업을 추가했다. [원본 실행 화면 수집](verification/m7/INCREMENT_183.md)

마운트된 프리뷰와 장시간 QA 실행 파일의 Mach-O 최소 OS·SDK를 대조한다. [빌드 대조](verification/m7/INCREMENT_182.md)

파일 작업 AppKit 회귀를 호스트 볼륨 조회에서 분리하고 시간 초과 시 마지막 단계와 프로세스 스택을 기록한다. [시간 초과 진단](verification/m7/INCREMENT_181.md)

격리된 개발 프리뷰 설치·교체·복원의 모든 단계에서 앱 아키텍처를 검사한다. [업데이트 검증](verification/m7/INCREMENT_180.md)

CI의 Apple Silicon·Intel에서 탐색·복사·충돌 처리 AppKit 회귀를 실행하도록 구성했다. [파일 작업 회귀](verification/m7/INCREMENT_179.md)

macOS 15의 두 CI 러너에서 유니버설 프리뷰를 설치하고 Launch Services로 실행하도록 구성했다. [설치 실행 검증](verification/m7/INCREMENT_178.md)

고정 원본에서 인벤토리를 다시 추출해 검토 기록을 보존한 상태로 대조할 수 있다. [원본 재대조](verification/m7/INCREMENT_177.md)

원본 대응 인벤토리에서 고정 SHA와 근거 파일의 존재를 CI로 검사하고 명령 팔레트의 근거 경로를 바로잡았다. [인벤토리 검증](verification/m7/INCREMENT_176.md)

정렬된 상세 목록의 행 사이에 새 항목이 들어올 때 기존 셀과 파일 선택을 유지한다. [정렬 및 힙 대조](verification/m7/INCREMENT_175.md)

스트리밍 상세 목록에서 끝에 새 행을 추가할 때 기존 셀과 선택을 보존한다. [스트리밍 목록 회귀](verification/m7/INCREMENT_174.md)

상세 목록이 비워지거나 채워질 때 행 단위 갱신으로 AppKit 관찰 객체의 증가를 줄였다. [메모리 대조](verification/m7/INCREMENT_173.md)

macOS 15의 Apple Silicon·Intel GitHub Actions에서 Swift 기본 회귀와 다섯 파일 시스템 실마운트 검사를 통과했다. [macOS CI](verification/m7/INCREMENT_172.md)

외부 환경이 없는 통합 시험을 Swift Testing이 건너뜀으로 표시한다. [통합 시험 상태](verification/m7/INCREMENT_171.md)

폴더 권한 작업 중단을 포함한 유니버설 프리뷰를 갱신하고 설치·교체·복원 및 기동을 확인했다. [프리뷰 검증](verification/m7/PREVIEW_0.1.0.md)

현재 엔진으로 FTP·FTPS·SFTP 루프백 통합 검사를 재실행했다. [원격 프로토콜 재검증](verification/m7/INCREMENT_170.md)

다섯 로컬 파일 시스템, APFS 강제 종료 복구, 시스템 휴지통을 현재 엔진 소스로 재검증했다. [로컬 볼륨 재검증](verification/m7/INCREMENT_169.md)

SMB 사전 검사에서 중단된 단계와 시험 폴더의 경로를 확인할 수 있다. [SMB 중단 진단](verification/m7/INCREMENT_168.md)

SMB 통합 시험 전에 공유의 파일 생성·읽기·이름 변경·삭제 응답을 확인한다. [SMB 사전 검사](verification/m7/INCREMENT_167.md)

권한 시트에서 30,000개 파일 변경을 중단하고 표시 건수와 실제 변경을 대조했다. [AppKit 중간 중단](verification/m7/INCREMENT_166.md)

APFS의 30,000개 파일 권한 변경을 세 차례 중간 중단하고 실제 파일 상태와 보고 건수를 대조했다. [중간 중단 검증](verification/m7/INCREMENT_165.md)

폴더 권한 일괄 적용 시트에서 작업 중단과 처리 결과를 제공한다. [중단 검증](verification/m7/INCREMENT_164.md)

현재 프리뷰 소스에서 10,000·100,000항목과 5분 유휴 후 탐색 성능을 측정했다. [성능 기록](verification/m7/INCREMENT_163.md)

하위 항목의 권한·ACL·소유권 변경을 담은 유니버설 프리뷰를 갱신했다. [설치·기동 검증](verification/m7/PREVIEW_0.1.0.md)

폴더 권한 시트에서 그룹·사용자 소유권에 하위 적용을 선택할 수 있다. [폴더 소유권 검증](verification/m7/INCREMENT_162.md)

폴더 권한 시트에서 확장 ACL을 하위 항목에도 적용한다. [폴더 ACL 검증](verification/m7/INCREMENT_161.md)

폴더 권한 시트에서 하위 항목에도 POSIX 권한을 적용할 수 있다. [폴더 권한 검증](verification/m7/INCREMENT_160.md)

파일 권한 시트에서 사용자 소유권과 macOS 권한을 표시한다. [사용자 소유권 검증](verification/m7/INCREMENT_159.md)

파일 속성에서 단일 항목의 그룹 소유권을 변경한다. [그룹 소유권 검증](verification/m7/INCREMENT_158.md)

권한·해시를 포함한 유니버설 프리뷰를 갱신했고 동일 소스의 8시간 전체 부하 시험을 시작했다. [프리뷰 및 부하 시험](verification/m7/INCREMENT_157.md)

ACL 편집기에서 macOS 사용자·그룹 선택 목록을 사용한다. [계정 목록 검증](verification/m7/INCREMENT_156.md)

계정의 짧은 이름으로 사용자·그룹 ACL 규칙을 추가한다. [계정 규칙 검증](verification/m7/INCREMENT_155.md)

파일 권한 시트에서 macOS 확장 ACL 항목을 추가·수정·삭제한다. [확장 ACL 검증](verification/m7/INCREMENT_154.md)

파일 속성에서 단일 항목의 POSIX 모드를 편집하고 확장 ACL을 조회한다. [파일 권한 검증](verification/m7/INCREMENT_153.md)

파일 속성 창에서 여섯 해시 알고리즘을 선택하고 해시값 또는 다른 파일과 비교한다. [파일 해시 검증](verification/m7/INCREMENT_152.md)

파일 이동 복구 변경을 포함한 유니버설 프리뷰를 갱신했다. Apple Silicon에서 설치·교체·복원과 Launch Services 기동 20회를 확인했다. [프리뷰 설치와 기동](verification/m7/PREVIEW_0.1.0.md)

AppKit 검증 스크립트가 실행별 시험 폴더를 만들고 결과 경로를 출력한다. [검증 폴더 격리](verification/m7/INCREMENT_151.md)

현재 소스에서 한국어·영어와 두 테마의 AppKit 검사가 조합별로 258개 통과했다. [AppKit 회귀 기록](verification/m7/INCREMENT_150.md)

백업 없는 교차 볼륨 이동도 복원본 게시 후 중단된 실행 취소를 재개할 수 있다. [일반 이동 실행 취소 복구](verification/m7/INCREMENT_149.md)

같은 볼륨 이동과 실행 취소에서 비덮어쓰기 게시 경로를 사용한다. [이동 충돌 보호](verification/m7/INCREMENT_148.md)

교차 볼륨 이동의 실행 취소에서 원래 경로에 생긴 파일이나 링크를 보호한다. [실행 취소 게시 검증](verification/m7/INCREMENT_147.md)

교체 이동의 백업 복원 직전 강제 종료와 재시작 뒤 충돌 보호를 검증했다. [강제 종료 복구](verification/m7/INCREMENT_146.md)

강제 종료 뒤 교체 이동 실행 취소에서 메타데이터만 바뀐 복원본의 보호를 검증했다. [강제 종료 복구](verification/m7/INCREMENT_145.md)

정식 DMG 검증에서 마운트한 앱을 격리 경로에 복사한 뒤 서명과 배포 정책을 다시 확인한다. [복사 후 검증](verification/m7/INCREMENT_144.md)

정식 DMG 다운로드 검증에 빌드 시 별도로 기록한 SHA-256 대조를 추가했다. [다운로드 이미지 대조](verification/m7/INCREMENT_143.md)

SMB 통합 시험에 앱의 폴더 목록과 외부 파일 변경 후 다시 읽기 검사를 추가했다. [SMB 목록 검증](verification/m7/INCREMENT_142.md)

SMB 통합 시험 전에 공유의 디렉터리 응답을 확인한다. [SMB 검증 기록](verification/m7/INCREMENT_141.md)

복사·이동 결과의 접근성 알림에 취소 건수와 저널 저장 오류를 포함한다. [접근성 알림 검증](verification/m7/INCREMENT_140.md)

최신 프리뷰와 동일한 소스에서 한국어·영어 AppKit 회귀를 실행했다. [AppKit 회귀 기록](verification/m7/INCREMENT_139.md)

최신 프리뷰와 앱 소스가 일치하는 최적화 QA 빌드에서 8시간 전체 부하 시험을 시작했다. [장시간 시험 시작 증거](verification/m7/INCREMENT_138.md)

장시간 시험 결과에 소스·바이너리 식별 정보와 완료 판정을 함께 기록한다. [장시간 결과 검증](verification/m7/INCREMENT_137.md)

최신 파일 전송 변경을 포함한 유니버설 프리뷰를 빌드해 설치·교체·복원과 Apple Silicon 기동 20회를 검증했다. [프리뷰 검증](verification/m7/PREVIEW_0.1.0.md)

APFS·exFAT 간 파일과 폴더의 접근 시간을 보존한다. [exFAT 접근 시간 검증](verification/m7/INCREMENT_135.md)

APFS 간 파일 전송 결과의 접근 시간을 검증 읽기 이후 복원한다. [접근 시간 검증](verification/m7/INCREMENT_134.md)

FAT32·HFS+ 전송의 생성 시간을 보존하고 실제 마운트 검사에 두 형식을 추가했다. [FAT32·HFS+ 생성 시간 검증](verification/m7/INCREMENT_133.md)

검색 회귀 시험이 고정 대기 시간 대신 검색 스트림과 완료 상태로 결과를 검증한다. [검색 시험 안정화](verification/m7/INCREMENT_132.md)

APFS와 exFAT 사이의 전송에서 파일과 폴더 생성 시간을 보존하고 검증한다. [exFAT 생성 시간 검증](verification/m7/INCREMENT_131.md)

APFS 폴더와 하위 폴더의 생성 시간을 보존하고 복원 중 심볼릭 링크를 거부한다. [폴더 생성 시간 검증](verification/m7/INCREMENT_130.md)

APFS 간 일반 파일의 복사와 이동에서 생성 시간을 보존하고 검증한다. [생성 시간 검증](verification/m7/INCREMENT_129.md)

이동 실행 취소에서 대상 파일을 중복으로 읽던 검증 경로를 통합했다. [이동 실행 취소 성능](verification/m7/INCREMENT_128.md)

같은 볼륨의 파일 이동에서 실행 취소용 검증 진행 상태를 표시하고 512 MiB 이동 지연을 측정했다. [대용량 이동 검증](verification/m7/INCREMENT_127.md)

이동을 다시 실행할 때 복원된 파일의 내용과 메타데이터가 바뀌었는지 확인한다. [이동 다시 실행 검증](verification/m7/INCREMENT_126.md)

이동 실행 취소에서 대상과 덮어쓰기 백업에 생긴 메타데이터 변경을 보호한다. [이동 실행 취소 검증](verification/m7/INCREMENT_125.md)

복사·폴더 병합 실행 취소에서 확장 속성, ACL과 수정 시간이 바뀐 복사본을 보존한다. [복사 실행 취소 검증](verification/m7/INCREMENT_124.md)

파일 전송 결과에서 ACL·권한·확장 속성·수정 시간의 검증 실패를 구분한다. [전송 검증 실패 안내](verification/m7/INCREMENT_123.md)

복사와 교차 볼륨 이동에서 수정 시간을 검증하고 exFAT 등 파일 시스템별 기록 정밀도를 반영한다. [수정 시간 검증](verification/m7/INCREMENT_122.md)

복사와 교차 볼륨 이동에서 ACL과 POSIX 권한을 확인한다. [파일 권한 검증](verification/m7/INCREMENT_121.md)

복사와 교차 볼륨 이동에서 Finder 태그 등 확장 속성을 비교하고, 전송 중 변경 시 원본을 보존한다. [확장 속성 검증](verification/m7/INCREMENT_120.md)

교체 백업이 없는 이전 폴더 이동의 실행 취소와 다시 실행에서 내부 파일의 리소스 포크를 보존한다. [이전 기록 호환성](verification/m7/INCREMENT_119.md)

최신 Git 동기화와 특수 파일명 처리를 담은 유니버설 프리뷰의 설치·교체·복원과 20회 기동을 검증했다. [프리뷰 검증](verification/m7/PREVIEW_0.1.0.md)

Git 동기화에서 설정된 upstream 브랜치에만 푸시하도록 수정했다. [M7 Git 동기화 검증](verification/m7/INCREMENT_113.md)

Git 병합 충돌 표시와 보조 패널 읽기 중단·재시도를 담은 유니버설 개발 프리뷰를 갱신했다. 설치·교체·복원을 확인했고 arm64 기동 20회의 정보 창 표시 p95는 575 ms였다. [프리뷰 설치·기동](verification/m7/PREVIEW_0.1.0.md)

분할 보기에서 보조 패널 폴더 읽기 중단과 재시도를 검증했다. [M7 보조 패널 읽기 복구](verification/m7/INCREMENT_111.md)

Git 병합 충돌을 상태 패널과 상세 목록의 Git 열에 표시한다. 실제 충돌 저장소에서 HEAD, 인덱스와 파일 보존을 검증했다. [M7 Git 충돌 검증](verification/m7/INCREMENT_108.md)

느린 시작 위치를 열 때 창 표시가 지연되는 경로를 수정했다. 새 유니버설 프리뷰의 Launch Services 기동 20회에서 정보 창 표시 p95는 520 ms였다. [M7 시작 폴더 복구](verification/m7/INCREMENT_107.md)

폴더 탐색 성능을 AppKit 목록이 갱신되는 시점에 기록한다. 최적화 QA 빌드에서 즉시 및 5분 유휴 후 탐색을 확인했다. [M7 목록 표시 계측](verification/m7/INCREMENT_105.md)

UI-01~20의 Windows 소스와 macOS 구현 구조를 대조했다. AppKit 캡처의 실제 테마를 검사하며 한국어·영어와 두 테마의 전체 회귀가 각각 254개씩 통과했다. [M7 화면 대조 및 테마 검증](verification/m7/INCREMENT_104.md)

복사와 같은 볼륨 이동의 실패 항목을 개별 재시도하고 일괄 이름 변경 미리보기에서 중복·누락·잘못된 이름을 검증한다. [복사 재시도](verification/m7/INCREMENT_101.md) · [이동 재시도](verification/m7/INCREMENT_102.md) · [이름 변경 사전 검사](verification/m7/INCREMENT_103.md)

닫은 창의 작업 공간을 저장한 뒤 AppKit 콘텐츠를 해제한다. [M7 창 종료 시 콘텐츠 해제](verification/m7/INCREMENT_95.md)

보조 브라우저를 독립 창과 네이티브 탭으로 각각 열고 닫는 장시간 대조를 추가했다. [M7 창·탭 부하 비교](verification/m7/INCREMENT_94.md)

최근 방문 기록 변경 시 홈의 최근 위치 목록만 갱신하고, 기존 드라이브·네트워크 뷰와 키보드 초점을 유지한다. [M7 홈 갱신 범위](verification/m7/INCREMENT_93.md)

상세 목록 셀 수가 제한된 장시간 시험에서 AppKit 관찰 객체의 보유를 확인하고 최근 위치 갱신 대조를 시작했다. [M7 중간 힙 비교](verification/m7/INCREMENT_92.md)

복사·이동 충돌 비교에 이미지와 PDF 첫 페이지의 썸네일을 표시한다. [M7 충돌 이미지·PDF 미리보기](verification/m7/INCREMENT_91.md)

복사·이동 충돌 창에서 원본과 기존 대상의 텍스트 미리보기를 비교한다. [M7 충돌 텍스트 미리보기](verification/m7/INCREMENT_90.md)

복사·이동 충돌 창에서 원본과 기존 대상의 경로·종류·파일 크기·수정일을 비교한다. [M7 충돌 정보 비교](verification/m7/INCREMENT_89.md)

장시간 메모리 시험에 파일 전송을 제외한 탐색·탭 반복 모드를 추가했다. [M7 탭 반복 부하 대조](verification/m7/INCREMENT_88.md)

분할 세션 복원 중 탭 드롭을 차단하고, 네이티브 탭 그룹에서 원본 탭 닫힘과 대상 창의 상태 보존을 검사한다. [M7 탭 드롭과 세션 복원](verification/m7/INCREMENT_87.md)

창 헤더의 탭 핸들을 파일 영역 가장자리에 놓아 좌우·상하 분할을 만든다. [M7 탭 드롭 분할](verification/m7/INCREMENT_86.md)

분할 보기와 전체 Spotlight 검색을 포함한 유니버설 프리뷰를 갱신했다. 이전 이미지에서 교체·복원하고 arm64에서 20회 기동을 확인했다. [M7 프리뷰 설치와 기동](verification/m7/PREVIEW_0.1.0.md)

AppKit 마우스 추적에서 좌우 구분선 이동을 확인하고, 최소 창 너비에서 보조 패널의 경로 입력과 폴더 이동을 검증한다. [M7 분할 조작 검증](verification/m7/INCREMENT_85.md)

최소 창 너비에서 좌우 분할 비율 유지와 기본 패널의 경로 입력 초점을 검증한다. [M7 최소 너비 검증](verification/m7/INCREMENT_84.md)

좌우 분할 시작 및 창 크기 변경 중 패널 비율을 유지한다. [M7 좌우 분할 검증](verification/m7/INCREMENT_83.md)

상하 분할의 콘텐츠 최소 높이 제약을 조정해 저장 비율을 복원한다. [M7 상하 분할 비율 검증](verification/m7/INCREMENT_82.md)

분할 전환과 닫기에서 표시 중인 보기로 키보드 초점을 복원하고, 양쪽 패널의 탐색 상태 저장·복원을 검사한다. [M7 분할 보기 검증](verification/m7/INCREMENT_81.md)

열려 있는 Quick Look을 다른 탐색 컨트롤러의 닫기 요청이 끊지 않도록 했다. [M7 Quick Look 검증](verification/m7/INCREMENT_80.md)

정보 패널에서 다중 선택 항목을 이전·다음으로 미리보고 상세 탭에서 파일과 폴더 개수를 확인할 수 있다. [M7 정보 패널 검증](verification/m7/INCREMENT_79.md)

Spotlight 콘텐츠 검색에 모든 인덱싱된 위치 범위를 추가했다. [M7 인덱스 범위 검색](verification/m7/INCREMENT_78.md)

검색 필드에서 방향키로 결과 목록에 이동하고 Return으로 기존 열기 동작을 실행할 수 있다. [M7 검색 키보드 검증](verification/m7/INCREMENT_77.md)

홈이나 다른 보기에서 상세 목록을 창에서 분리하고, 상세 보기로 돌아오면 같은 테이블을 다시 붙인다. 125사이클 탐색 대조에서 셀 보유가 누적되지 않았다. [M7 상세 목록 메모리 검증](verification/m7/INCREMENT_76.md)

장시간 탐색에서 주 창의 상세 목록 셀 중 아직 해제되지 않은 개수를 기록한다. 탐색과 전체 부하 각각에서 계측을 확인했다. [M7 상세 셀 계측](verification/m7/INCREMENT_75.md)

최신 소스의 유니버설 프리뷰를 갱신했다. Apple Silicon에서 설치, 손상된 교체본 거부, 구형 탭 세션 변환, 교체 및 이전 앱 복원을 확인했다. [M7 프리뷰 설치 검증](verification/m7/PREVIEW_0.1.0.md)

장시간 메모리 분석에 탐색 대조 모드를 추가하고 전체 모드와 같은 바이너리에서 검증했다. [M7 탐색 대조 시험](verification/m7/INCREMENT_74.md)

프리뷰 시작 검증에 실제 프로세스 아키텍처 및 macOS 버전 대조를 추가했다. [M7 실행 환경 검증](verification/m7/INCREMENT_73.md)

로딩 버튼의 시스템 이미지 두 개를 재사용하고, 로딩 취소 뒤 이미지와 접근성 레이블 복원을 검증했다. [M7 로딩 버튼 검증](verification/m7/INCREMENT_72.md)

세션 복원 뒤 종료 시 마지막 브라우저 탭을 저장한다. [M7 선택 탭 저장](verification/m7/INCREMENT_71.md)

저장 세션의 일부가 손상돼도 정상 탭을 복원한다. [M7 부분 세션 복구](verification/m7/INCREMENT_71.md)

손상된 분할 세션이 시작을 막지 않도록 검사하고, 구형 탭 또는 시작 폴더로 복구되는지 실제 앱에서 확인했다. [M7 세션 복구](verification/m7/INCREMENT_70.md)

파일 선택부터 홈 탐색·붙여넣기·충돌 건너뛰기까지 이어지는 AppKit 회귀를 네 언어·테마 조합에서 통과했다. [M7 복사 동선 검증](verification/m7/INCREMENT_69.md)

다운로드한 정식 DMG와 앱 서명을 배포자가 별도로 제공한 Team ID와 대조할 수 있다. [M7 출시 팀 검증](verification/m7/INCREMENT_21.md)

프리뷰 교체 후 정상 종료 시 구형 탭을 새 형식으로 저장하고, 이전 프리뷰로 복원한 뒤 다시 열리는지 확인했다. [M7 탭 세션 복원](verification/m7/PREVIEW_0.1.0.md)

프리뷰 설치·교체·복원 각 단계에서 네 설정과 사용자 파일 내용이 유지되는지 확인한다. [M7 설정 보존 검증](verification/m7/PREVIEW_0.1.0.md)

정식 DMG 빌드에서 다운로드와 같은 검증을 실행한 뒤 산출물을 교체한다. [M7 산출물 교체 검증](verification/m7/INCREMENT_16.md)

정식 DMG 검증에서 이미지와 내부 앱에 같은 팀의 Developer ID Application 서명을 요구한다. [M7 정식 DMG 검증](verification/m7/INCREMENT_21.md)

로컬 임시 경로에서 프리뷰 설치·교체·복원을 재검증하고, RSS와 물리 메모리를 함께 기록하는 후보로 8시간 시험을 시작했다. [M7 로컬 설치와 장시간 시험](verification/m7/INCREMENT_68.md)

장시간 시험에서 사이클별 RSS와 macOS 물리 메모리 사용량을 함께 측정한다. [M7 메모리 계측 검증](verification/m7/INCREMENT_67.md)

Git 열을 숨긴 창에서는 목록용 Git 조회를 생략한다. [M7 Git 조회 검증](verification/m7/INCREMENT_66.md)

장시간 시험의 프로세스 종료 코드를 보고서와 함께 보존하고, 상세 목록 재사용 후보로 8시간 시험을 시작했다. [M7 장시간 종료 증거](verification/m7/INCREMENT_65.md)

상세 행과 표시 상태가 같으면 기존 테이블 셀을 재사용한다. [M7 상세 목록 셀 검증](verification/m7/INCREMENT_64.md)

파일 변경을 감지했을 때 파일 전용 아이콘만 다시 읽고, 공통 아이콘은 재사용한다. [M7 아이콘 갱신 검증](verification/m7/INCREMENT_63.md)

전체 AppKit 회귀 시험도 표준화된 임시 경로에서 실행해 한국어·영어와 밝은·어두운 테마 각 조합의 219개 검사를 통과했다. [M7 전체 AppKit 회귀](verification/m7/INCREMENT_62.md)

임시 경로에서 AppKit 회귀를 다시 실행해 그리드 선택 복원과 템플릿 파일 생성을 포함한 53개 검사가 네 언어·테마 조합에서 모두 통과했다. [M7 AppKit 재검증](verification/m7/INCREMENT_61.md)

최근 위치·환경설정·볼륨 목록이 바뀌지 않으면 홈 화면의 기존 뷰를 재사용한다. [M7 홈 화면 회귀](verification/m7/INCREMENT_60.md)

최신 후보를 로컬 임시 경로에서 빌드해 8시간 탐색·복사·탭 시험을 시작했다. [M7 로컬 장시간 시험](verification/m7/INCREMENT_59.md)

최근 위치 갱신을 홈 화면에 적용하고, 장시간 시험에서 브라우저와 기대 경로에 동일한 URL 표준화를 적용했다. [M7 최근 위치와 장시간 시험 경로](verification/m7/INCREMENT_58.md)

Git 상태·커밋 정보 응답이 도착하면 화면의 Git 셀만 갱신한다. 장시간 시험에서 목록 준비 확인이 실패했을 때 로딩과 감시 상태도 보고한다. [M7 Git 열과 장시간 시험](verification/m7/INCREMENT_57.md)

장시간 탐색 중 AppKit이 파일 목록 셀과 관찰 객체를 계속 보유하는 경로를 힙에서 확인했다. [M7 장시간 메모리 분석](verification/m7/INCREMENT_56.md)

배포 이미지 생성 전에 설치 링크, 라이선스, 릴리스 노트, 앱 구성과 두 아키텍처의 의존성을 검사한다. 정식 다운로드 검증에도 같은 검사를 연결했다. [M7 DMG 내용물 검증](verification/m7/INCREMENT_55.md)

상세 목록 셀 재사용과 Git 조회 개선을 포함한 유니버설 프리뷰가 격리 설치·교체·복원 시험을 통과했다. [M7 최신 프리뷰 검증](verification/m7/PREVIEW_0.1.0.md)

임시 APFS 볼륨 간 교체 이동을 실행 취소하는 테스트 프로세스를 강제 종료하고 새 프로세스에서 복원을 재개했다. [M7 강제 종료 검증](verification/m7/INCREMENT_54.md)

교차 볼륨 교체 이동 실행 취소 중 두 위치에 남은 사본이 여전히 일치하는지 확인하고 백업 복원을 재개한다. [M7 중복 사본 복구](verification/m7/INCREMENT_53.md)

교차 볼륨의 교체 이동 실행 취소에서 검증된 복사본을 기록해 재시도를 지원한다. [M7 교차 볼륨 실행 취소 복구](verification/m7/INCREMENT_52.md)

같은 볼륨의 교체 이동 실행 취소에서 원래 위치 복원과 저널 갱신 사이에 중단된 상태를 복구한다. [M7 같은 볼륨 실행 취소 복구](verification/m7/INCREMENT_51.md)

교체 이동 실행 취소에서 백업 복원 전에 재시도 상태를 저널에 저장한다. [M7 복원 저널 저장](verification/m7/INCREMENT_50.md)

교체 이동 실행 취소 도중 대상이 점유되면 충돌로 표시하고, 실제 저널을 읽어 백업만 재시도하는 동작을 검증했다. [M7 실행 취소 중 경로 충돌](verification/m7/INCREMENT_49.md)

교체 이동 실행 취소를 재시도할 때 남은 백업 복원만 수행할 수 있다. [M7 교체 이동 실행 취소 재시도](verification/m7/INCREMENT_48.md)

교체 이동 취소 시 외부에서 변경된 백업을 보존하고 경로를 표시한다. [M7 변경된 교체 백업 보존](verification/m7/INCREMENT_47.md)

이동 창에 실행 취소를 위한 폴더 검증 단계를 표시하고, 교체 백업 전에 취소하면 원본과 대상을 보존한다. [M7 폴더 검증 중 취소](verification/m7/INCREMENT_46.md)

같은 볼륨의 폴더 이동 실행 취소에서도 하위 파일 변경을 보호한다. [M7 같은 볼륨의 폴더 실행 취소](verification/m7/INCREMENT_45.md)

교차 볼륨 이동 실행 취소에서 대상과 교체 백업 폴더 내부의 변경을 확인한다. [M7 폴더 실행 취소 검증](verification/m7/INCREMENT_44.md)

교차 볼륨 이동에서 게시 직후 대상 파일이 교체되면 원본을 보존한다. [M7 게시 후 변경 감지](verification/m7/INCREMENT_43.md)

Launch Services에서 유니버설 프리뷰를 열어 메뉴 응답을 20회 측정했다. [M7 Launch Services 시작](verification/m7/INCREMENT_42.md)

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

[이동 위치 기록 후 재기동 복원](verification/m7/INCREMENT_304.md)은 실제 `movedToTrash` 기록 직후 QA 자식을 SIGKILL하고 다른 앱 PID의 복원 동작으로 보관소에 되돌린다. 네 언어·외형 조합 각각 19개, 위치 미기록 회귀 14개, 기존 수신 계약 53개와 Swift 성공 304개·건너뜀 18개를 확인했다. 원본 기록·수신 내용·게시 복사본을 보존하며 Release에는 종료 지점 진입을 포함하지 않는다. 최신 두 CPU·장시간·실제 접근성·정식 서명 수용은 진행 중이다.

[7z SDK 목록 helper](verification/m7/INCREMENT_345.md)는 공식 고정 소스의 구조화된 속성 API와 길이 프레임을 구현했다. ARM 실제 암호·Unicode/줄바꿈·링크·원본 변경·잘못된 요청 등 34개 조건이 통과했고 Intel 교차 빌드와 두 CPU 최소 배포 메타데이터를 확인했다. 앱 연결·추출·생성·자원 격리·Intel native 수용은 미완료다. 직전 두 원격 실행은 ARM 성공·Intel 실패이며 344 Intel Spotlight EBUSY와 343 Intel Git scheduling 실패는 별도 추적한다. 인증서·공증은 준비 중이고 M7 정식 출시는 계속 진행 중이다.

[7z 선택 항목 추출 stream](verification/m7/INCREMENT_346.md)은 같은 원본 FD에서 일반 파일을 전용 출력 파이프로 추출하고 크기·상한·링크·원본 변경·SDK 최종 오류를 검사한다. ARM 목록/추출 조건 총 59개가 통과했고 Intel 교차 빌드도 통과했다. 직전 345 목록 helper는 macOS 15 ARM·Intel native 보고서 각각 34개 통과를 확인했다. 앱의 안전한 staging/게시·취소·자원 격리·생성 연결과 최신 두 CPU 추출 수용은 남아 있다. M7 정식 출시는 진행 중이다.
