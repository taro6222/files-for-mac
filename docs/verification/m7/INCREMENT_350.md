# M7 Increment 350 — 기존 폴더 추출과 7z 암호 UI 연결

상태: 구현·로컬 headless 검증과 후속 원격 ARM UI 검사가 통과했다. Intel 전체 수용과 M7 출시는 미완료다.

## 기능

ArchiveWindow와 일괄 추출이 7z에는 검증된 bundle factory를 사용한다. ZIP/RAR의 기존 경로는 유지한다. SDK 없는 SwiftPM/Xcode 개발 실행에서는 일반 7z의 기존 libarchive 경로를 유지한다. SDK marker가 있는데 검증이 실패하면 조용히 다른 SDK를 실행하지 않고 사용자 오류를 표시한다. DEBUG UI 검증만 별도 서명 bundle을 주입할 수 있다.

헤더 암호화 7z는 목록을 열 때 ‘열기’ 암호 시트를 표시한다. 일괄 추출은 해당 작업 안에서 입력한 암호를 이어 사용하고, 개별 창의 후속 추출은 별도 암호 입력을 받는다. 입력은 시트 종료 시 지운다. 틀린 암호·취소·변경된 원본·한도 초과·bundle 오류·보존한 임시 결과를 한국어/영어 메시지로 연결한다. 오래된 작업이 새 창 내용을 덮어쓰지 않도록 작업 ID를 확인하고, 읽기 취소와 게시 후 완료도 창이 무한 실행 상태로 남지 않게 처리한다.

기존 폴더용 Core extract API를 추가했다. 전체 내용을 private staging에서 검증한 뒤 top-level별 descriptor-relative RENAME_EXCL로 게시한다. 사전 및 실제 게시에서 충돌을 거부하며 기존 폴더 내용을 덮어쓰지 않는다. 중간 오류/취소는 identity·파일 크기/mtime/ctime 및 하위 항목을 확인해 자신이 게시한 결과만 되돌린다. 교체되거나 변경된 결과는 건드리지 않고 staging/영향 위치를 publicationRecovery 오류로 반환한다. 여러 이름 게시를 단일 원자적 동작이나 전원 장애 복구로 표현하지 않는다.

here/smart/child 배치는 유지한다. child 이름은 atomic mkdir로 예약하고 기존 동명 폴더가 있으면 다음 이름을 선택한다. 실패 시 자신이 만든 동일 inode의 빈 폴더만 rmdir로 정리한다. 지원 창의 암호 열은 ZIP ‘생성·추출’, 확인된 7z ‘추출’로 구분한다. 완전한 암호 생성/추출을 뜻하는 기존 Core password Bool은 7z에서 false를 유지한다.

## 검증과 남은 항목

headless SDK 검사 23개가 통과했다. 새 네 함수는 암호 7z를 기존 폴더에 추출하면서 무관한 항목/원본 보존, 게시 후 두 번째 이름 충돌 시 첫 결과 복원, 외부 교체된 첫 결과/자신의 staging 보존, 부분 게시 후 취소 rollback을 실제로 검증한다. Core 전체는 419개 중 성공 400개·환경 건너뜀 19개로 통과했다. [소스/결과 해시](archive-ui-350-verification.json).

직전 349 ARM CI는 SwiftPM test container의 정적 signature 상태를 제품 앱과 같다고 가정한 단언에서 실패했다. 실행 중인 코드의 designated identity 확인은 성공했으므로, 이 단언을 identity primitive의 실제 계약으로 고쳤다. 실제 앱/helper의 strict signature·hash·Team/identifier 검증은 약화하지 않았다. 수정한 검사를 포함한 23개도 다시 통과했다.

최종 Debug/Release 빌드도 통과했다.

새 AppKit 검사 6개를 추가했다: 암호화 목록과 틀린 암호 재열기, 개별 추출/재시도/취소, 일괄 세 배치, 기존 child 이름 충돌, 헤더 읽기 취소, 작업별 암호 지원 표시. verify-ui.sh는 서명된 SDK fixture를 준비해 네 조합에 재사용한다. DEBUG에서 실제 bundle resolver와 UI/추출 경로를 호출하며 암호 입력 screenshot도 수집한다. 로컬 사용자 Mac에서는 UI 반복 시험을 실행하지 않았으며 새 검사는 원격 CI에서 확인한다. 초기 기록에서는 이 여섯 조건을 성공으로 집계하지 않았다. 아래 후속 확인에서 원격 ARM 결과를 기록한다.

장시간 시험 6종은 사용자 요청으로 종료한 상태를 유지하고 자동 재시작하지 않았다. 새 코드의 decoder 메모리/권한 격리·메타데이터 복원·7z 암호 생성/세부 옵션/분할, 지원 환경/원본 UI/물리 입력/VoiceOver·서명/공증은 남아 있다. 배포 SDK를 포함하는 Xcode 개발 산출물의 자동 패키징도 별도 연결 항목이다.

## 352단계 후속 확인

보존한 실행 45791755783 원문에서 ARM의 네 조합 각각 전체 324개·탭 경계 18개 모두 true를 확인했다. 전체 UI 단계의 실패는 과거 318개 단언 때문이며 351에서 수정했다. Intel 파일 작업 UI는 Cocoa 1570으로 실패해 두 CPU 전체 수용은 미완료다. [후속 근거](INCREMENT_352.md)와 [원문 집계/해시](remote-350-followup-352.json)를 따른다.
