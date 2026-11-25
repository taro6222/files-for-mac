# M7 Increment 304 — 이동 위치 기록 후 강제 종료와 새 프로세스 복원

상태: 구현·로컬 검증 통과. M7 정식 출시 검증은 진행 중이다.

F17 수신 보관본 정리에서 실제 휴지통 이동과 `movedToTrash` 기록 저장 직후, 후속 검증 전에 전용 QA 자식을 멈춘다. Python 부모가 기록·nonce·살아 있는 자식 PID를 대조하고 그 자식만 SIGKILL한다. 다른 FilesMac PID에서 디스크 기록을 새로 읽어 실제 복원 버튼의 동작 경로로 보관소에 되돌린다. 전원 차단·디스크 영속성 검증으로 확대하지 않는다.

새 프로세스는 저장된 위치·폴더 identity·수신 파일명·복원 가능 상태를 확인한다. 복원 중 동시 파일 작업 차단·취소 제공, 최소 창의 버튼·표 정렬, 복원 후 재복원 방지와 별도 복원 기록도 검사한다. 한글 수신 내용·이미 게시한 복사본·원본 정리 기록의 바이트가 유지되는지 대조한다. QA 정리는 동일 identity인 자체 fixture만 격리 폴더로 되돌리며 휴지통 전체를 비우지 않는다.

기존 위치 미기록 시나리오는 그대로 유지한다. `--checkpoint unrecorded|journaled`로 선택하고 CI에서 둘 다 실행한다. 종료 지점용 공개 진입은 DEBUG 전용이며 Release 바이너리에 해당 심볼이 없는 것을 확인했다. 수신 계약의 기본 `received.txt` 검증을 유지하면서 재기동 시험의 한글 파일명도 받도록 QA helper를 확장했다.

검증 결과:

- Debug·Release 빌드 성공. 고정 Debug 바이너리 SHA-256 `e290687243f9d0bcdd2532c3ec51e352bd77a3437d5c637865f0a81a1e172029`.
- 전체 Swift 322개 보고: 성공 304개, 별도 환경 건너뜀 18개.
- 위치 기록 후 실제 SIGKILL·재기동: 한국어/영어 × 밝게/어둡게 각각 19개 통과.
- 위치 미기록 회귀 14개, 기존 수신·복원 AppKit 계약 53개 통과.
- 다섯 강제 종료 시험 모두 다른 준비/검사 PID와 SIGKILL 종료 코드 -9를 확인했다. 각 시험의 자체 휴지통 보관본은 회수됐고 내용·identity를 보존했다.
- 원본 결과·캡처·소스/로그 해시는 [검증 기록](journaled-restart-verification.json)에 저장한다. [한국어 밝게](journaled-restart-ko-light.png), [한국어 어둡게](journaled-restart-ko-dark.png), [영어 밝게](journaled-restart-en-light.png), [영어 어둡게](journaled-restart-en-dark.png).

이는 전용 앱의 프로그램 방식 AppKit 검증이다. 실제 마우스·키보드·SDK 드래그·VoiceOver 수용은 별도다. 이번 단위에서는 전체 283개 UI·마운트 행렬을 재실행하지 않았으며 303단계의 결과를 새 소스의 결과로 옮겨 쓰지 않는다. 최신 소스 두 CPU 원격 검증·장시간 시험·최소 OS·정식 설치 수용은 남아 있다. 기존 8시간 시험은 이전 소스의 기준 실행으로 계속되며 최신 후보 시험과 구분한다. Developer ID 인증서와 notarytool 프로필은 사용자 준비 중이므로 서명·공증·다운로드 후 Gatekeeper 수용을 완료로 표시하지 않는다.
