# M7 Increment 359 — 7z 수정 시각·Unix 권한 복원

상태: 생성·추출의 수정 시각과 Unix rwx 권한 연결 및 로컬 headless 검증 완료. 다른 메타데이터·최신 지원 환경과 M7 정식 출시는 미완료다.

## 생성과 프로토콜

SDK의 FILETIME 수정 시각을 Unix 초·나노초(100ns 단위)로 변환하고 Unix 확장 attribute의 rwx 권한과 함께 항목별 구조화 metadata로 전달한다. Windows attribute를 Unix mode로 오인하지 않으며 값이 없는 항목에는 private 기본 권한을 유지한다. 부모는 권한 범위·날짜/나노초 범위·날짜 쌍과 숫자 형식을 확인한 뒤에만 staging을 만든다. 기존 진단 응답의 metadata 부재도 허용한다.

실제 생성→복원 시험으로 생성 callback이 kpidPosixAttrib만 제공해 7z에 권한이 저장되지 않던 누락을 발견했다. SDK Get_WinAttribPosix_From_PosixMode와 같은 Unix 확장·파일/폴더·읽기 전용 표현을 kpidAttrib에도 제공하도록 수정했다. 생성 archive에는 원래 Unix mode를 기록하지만 복원은 rwx만 적용한다. setuid/setgid/sticky·소유자·ACL·xattr는 적용하지 않는다. birthtime/access-time 복원도 이번 범위에 포함하지 않는다.

## 적용과 실패 보존

파일은 정확한 크기/내용 처리가 끝난 열린 출력 FD에 futimens/fchmod를 적용하고 결과를 fstat으로 다시 읽는다. 저장소가 날짜를 보정하거나 권한을 다르게 적용하면 성공으로 집계하지 않는다. 수정한 mode/time/ctime 스냅샷을 기존 외부 변경 검증에 연결한다. 디렉터리는 모든 항목 기록이 끝난 시점에 identity와 staging 권한을 확인해 시각을 봉인한다. 게시 뒤 외부에서 디렉터리 시각·권한을 바꿔도 원래 archive 값으로 덮어쓰지 않고 보존한다.

디렉터리 최종 metadata는 깊은 경로부터 적용해 000/0111 권한의 부모도 하위 항목 생성·검증을 막지 않는다. 새 대상은 최종 metadata 적용 뒤 새 폴더 하나를 no-replace rename한다. 기존 폴더는 기존 top-level별 이동·검증을 마친 뒤 디렉터리 metadata를 마무리한다. 이 여러 항목 처리는 하나의 원자적 작업이 아니다.

제한 권한 적용 중 취소·실패로 전체 트리를 재검증할 수 없으면 권한을 강제로 바꿔 삭제/rollback하지 않는다. 새 대상은 stagingPreserved, 기존 대상은 publicationRecovery로 위치를 돌려주며 성공으로 표시하지 않는다. 사용자 안내도 외부 변경만을 단정하지 않고 안전하게 정리/복원하지 못한 위치를 설명하도록 수정했다.

## 검증

- 최종 Release 번들의 실제 SDK·서명을 사용한 Swift/SDK 52개가 건너뜀 없이 13.114초에 통과했다. 1970년 이전 날짜·100ns 시각, 실행 파일·읽기 전용 파일과 폴더의 생성/복원, 특권 비트 제거, 새/기존 대상과 기존 파일 보존을 확인했다.
- 000/0111 디렉터리와 000 파일의 새/기존 대상 추출, 잘못된 metadata 여덟 종류의 staging 전 거부, 게시된 폴더의 외부 시각 변경 보존을 확인했다. 파일 시스템이 표현하지 못하는 날짜 때문에 실패할 때 제한된 하위 폴더·내용과 정확한 복구 위치를 보존했다.
- 실제 최종 번들의 native 경계 117개가 통과했다. 독립 공식 7-Zip으로 만든 암호 archive의 파일/폴더 수정 시각·Unix 권한과 특권 비트 제거를 확인하고 기존 분할·FD·생성·손상 검증을 유지했다.
- Debug 전체 21.11초, 디렉터리 봉인 포함 18.61초, 최종 시험 제품 8.03초, Release 최종 32.51초와 preview 번들의 구성·서명 검증이 통과했다. 로컬 GUI·전체 AppKit·장시간 시험을 실행하지 않았다.

첫 생성/복원 검사에서 날짜는 일치했지만 권한 여덟 단언이 실패한 기록을 보존했다. kpidAttrib 기록을 추가한 뒤 새 SDK와 최종 번들에서 통과했다. 별도 짧은 파일 시스템 probe는 mode 000 디렉터리를 O_RDONLY/O_SEARCH/O_EVTONLY로 다시 열 수 없음을 확인했다. 또한 futimens가 성공을 반환해도 매우 먼 날짜를 `9223372036.854775807`초로 보정하는 실제 동작을 확인해 사후 값 검사를 검증했다. [소스·결과·로그 해시](metadata-359-verification.json)를 따른다.

## 원격 검증과 남은 항목

이전 356 소스 Intel 작업은 빌드 20분 시간 초과였고, 358 소스 ARM 작업은 빌드 12분 시간 초과였다. 컴파일 오류로 단정하지 않으며 이번 조회에서 358 Intel은 실행 중이다. 원격 최신 소스 두 CPU 수용을 통과했다고 집계하지 않는다.

기존 workflow는 push마다 같은 그룹의 실행 중 검증을 취소하도록 설정돼 있었다. cancel-in-progress를 false로 바꿔 실행 중 검증은 끝내고 기본 단일 pending 그룹에는 최신 push를 남긴다. [GitHub 공식 concurrency 규칙](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)을 따르며 YAML 구문과 해당 false 값을 확인했다. 빌드 제한 시간은 늘리지 않았다. 원격 빌드 시간 초과 원인과 수정 후 실행 수용은 남아 있다.

다른 metadata 속성·DOS attribute 대응·타 파일 시스템 정밀도 수용, helper 파일/네트워크 권한과 CPU/프로세스 트리 경계, 큰 생성 계획 프레임, 최신 지원 OS/CPU·실제 입력/VoiceOver·원본 UI 대조·정식 서명/공증도 남아 있다. 인증서/프로필은 사용자 준비 중이며 로컬 장시간 시험은 자동 재시작하지 않는다.
