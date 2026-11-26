# M7 Increment 361 — 빌드 진단 취소의 EPERM 수정

상태: 진단 도구의 취소 오류 재현·수정과 headless 검증 완료. 실제 수정 소스의 원격 수용·ARM 빌드 시간 초과 원인과 M7 정식 출시는 미완료다.

## 확인한 원인과 수정

360 소스 Intel 작업은 build monitor lifecycle에서 실패했다. artifact의 cancellation.log는 SIGKILL한 직접 자식을 wait한 뒤 finally에서 같은 그룹에 다시 SIGKILL해 EPERM이 발생하고 result.json 작성에 도달하지 못했음을 보여 준다. 앱 컴파일 실패와 구분한다.

그룹 강제 종료를 완료한 경로는 finally에서 재전송하지 않는다. 정상 SIGTERM으로 그룹이 이미 종료된 경우도 다루며, EPERM이 나면 현재 ps의 해당 그룹 구성원 상태를 확인한다. 살아 있는 항목이 있으면 권한 오류를 유지한다. 구성원이 없거나 terminal zombie만 있으면 이미 종료된 것으로 처리해 보고서를 남긴다. 단순 권한 오류를 무조건 성공으로 바꾸지 않는다. 빌드 재시작·관찰 제한·컴파일 명령·CI 제한 시간은 바꾸지 않았다.

## 검증과 원격 상태

짧은 실제 프로세스 그룹에 두 번째 SIGKILL의 EPERM을 주입해 수정 전 코드에서 원격과 같은 traceback·보고서 누락을 재현했다. 수정 후 같은 조건에서 단 한 번의 강제 종료, 직접 자식 회수, 손자 terminal 상태·sample 회수와 취소 코드 143을 확인했다. 정상 SIGTERM 종료 뒤 EPERM도 현재 그룹의 종료 상태를 확인해 보고서를 보존한다. 기존 출력·실패 코드·관찰 중 같은 빌드 유지까지 19개 검사가 모두 통과했다.

이전 358 실행은 완료됐고 ARM Debug 12분 시간 초과로 전체 실패다. Intel 작업은 성공했으며 Debug 빌드 1014.81초, 기본 Swift 성공 398개·환경 건너뜀 44개와 파일 작업/복구·프리뷰 패키징/설치 기동을 확인했다. 이 시간을 근거로 ARM의 원인을 단정하거나 제한을 늘리지 않는다. 최신 metadata·격리 소스와 전체 AppKit/VoiceOver 수용을 대신하지도 않는다. 360 Intel 진단 실패는 이번 수정의 실제 원격 재수용이 필요하다.

[소스·실패 재현·결과 해시](cancellation-361-verification.json)를 보존한다. 앱/SDK 코드는 이 커밋에서 바꾸지 않았고 앱 빌드나 GUI 회귀를 반복하지 않았다. 로컬 GUI·장시간 시험은 시작하지 않았다.

## 병행한 격리 실험 — 제품 미반영

별도 짧은 native App Sandbox probe는 직접 원본 경로 열기·읽기 FD의 chmod·루프백 connect를 EPERM으로 거부하면서 전달받은 FD 읽기/쓰기·기존 Unix socket 전송·bundle 내부 라이브러리 로드를 허용했다. 데이터는 시험용 source/output뿐이며 프로세스는 종료했다.

기존 SDK 단일 실행 파일에 entitlement만 추가하면 코드 서명 정보의 CFBundleIdentifier 부재로 sandbox 초기화가 SIGTRAP했다. [Apple의 Info.plist 내장 설정](https://developer.apple.com/documentation/xcode/build-settings-reference)과 같은 __TEXT,__info_plist를 내장한 별도 후보는 초기화를 통과했다. 기존 Frameworks 경로에서는 sdk-load 실패였고 helper와 같은 디렉터리의 동일 라이브러리를 명시했을 때 실제 FD 기반 암호 목록/추출·실패 정리 시험이 통과했다. 이 결과는 라이브러리 위치와 권한 경계의 제품 연결 방향을 정하는 증거다.

이 후보는 명시적 provider 시험이며 기존 bundled factory의 전체 layout/entitlement 검증을 통과한 제품으로 표시하지 않는다. 빌드 recipe 시제품 변경은 patch와 별도 후보/로그로 보존하고 제품 소스에는 남기지 않았다. 이어서 layout·서명·권한 검증과 전체 FD 동작을 연결해야 한다. 일반 probe의 sandbox 컨테이너 메타데이터와 시험 기록도 보존했다.

helper 격리·나머지 metadata·큰 생성 계획, 최신 원격/지원 OS/CPU·실제 입력/VoiceOver·원본 UI 대조·정식 서명/공증 게이트는 열린 상태다. 인증서/프로필은 사용자 준비 중이며 로컬 장시간 시험은 자동 재시작하지 않는다.
