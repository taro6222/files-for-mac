# 개발 현황

갱신: 2026-11-13

## 이번 구현 단위

M2 서른한 번째 개발 단위로 실제 macOS 시스템 휴지통 이동·복원 왕복 검증을 추가했고 M2는 진행 중이다. M0/M1의 미검증 항목은 별도 유지한다.

| 영역 | 상태 | 내용 |
|---|---|---|
| 원격 기반 | 완료 | 지정 origin의 초기 LICENSE/이력 보존 |
| 기준 원본 | 완료 | v4.2.9/SHA 고정 |
| 원본 인벤토리 | 진행 | 202 명령 후보·143 설정·33 화면 소스. 전수 동작 검증 아님 |
| 네이티브 앱 | 구현 | AppKit 창·네이티브 탭 그룹·사이드바·홈·상세 목록·경로 |
| 로컬 I/O | 검증 | 배치 열거·숨김 항목·메타데이터·파일 identity·오류 상태 |
| 탐색 상태 | 검증 | 히스토리·선택 복원·외부 rename 대응·오래된 비동기 결과 방지 |
| 파일 목록 | 구현 | 다중 선택·자연 정렬·열 정렬/재배치/크기 저장 |
| 편의 기능 | 구현 | 경로 추천·확장자 옵션·공유 즐겨찾기 순서·홈 용량·최근 기록 삭제 |
| 테스트 | 통과 | 78개 Swift Testing, 실제 볼륨 매트릭스·시스템 휴지통 진입점과 기존 workspace·파일 작업 회귀 검증, 기존 M1 UI 기록은 별도 유지 |
| 파일 복사 | 구현 | 대상 폴더 선택·클립보드·양쪽 유지/건너뛰기·내용 검증·취소·항목별 결과·JSON 저널·안전 실행 취소, 다중 선택 폴더 병합·통합 Undo |
| 느린 폴더 복구 | 구현 | 읽기 중단·늦은 결과 차단·불완전 목록 안내·명시적 재시도 |
| 접근 복구 | 부분 검증 | 오류 화면 재시도·폴더 선택, 시스템 선택 후 Desktop fixture 읽기 성공; 재실행 읽기 확인; 감시는 연결 대기 |
| 실제 UI | 부분 확인 | 900×600·한/영·두 테마·10k 목록·POSIX 권한 오류, M2 병합·분할·Undo 4조합 확인, 이미지 보관 |
| 폴더 감시 | 검증 | 연결 중/실패 구분, 명시적 재등록, 등록 실패 후 복구·실제 변경 반영 |
| 생성·이름 변경 | 구현 | 새 폴더, 선택 항목으로 새 폴더, 단일 이름 검증, 배치 패턴·미리보기·충돌 검사·순환 교환·결과 창 |
| 탭 탐색 | 구현 중 | 네이티브 탭 생성·복제·순서 변경/분리 기반, 탭별 히스토리·선택·스크롤·정렬·숨김 설정, 닫은 탭 및 재실행 복원 |
| 분할 보기 | 구현 중 | 실제 두 목록, pane별 탐색·파일 작업·FSEvents 감시·숨김·정렬, 분할 축·비율·활성 pane·두 상태 복원 |
| 드래그 앤 드롭 | 구현 중 | 양쪽 pane 파일 URL 송수신, 폴더/현재 위치 drop, Option 복사·Command 이동, 안전 엔진 및 충돌 대화상자 연결 |
| 휴지통 이동 | 검증 | 항목별 결과 표시·실패 분리·저널 기록, 실제 시스템 휴지통 이동 성공 |
| 휴지통 복원 | 검증 | 휴지통 항목 선택 복원(대상 폴더 선택) 동작과 `restoreFromTrash` 결과 창 연결, 실제 시스템 휴지통 왕복 복원·내용 확인 성공 |
| 이동 | 구현 중 | 동일/교차 볼륨 이동, 검증·교체 백업·안전 실행 취소, 사용자 취소, 단계별 상태와 진행 막대; APFS/APFSX/exFAT 통과 |
| 영구 삭제 | 구현 중 | 선택 항목 영구 삭제(복구 불가 경고), 항목별 상태 보고, 작업 창, 저널 파일 |

다음 M2 작업은 실제 SMB 네트워크 볼륨 검증으로 M2 수용 기준의 남은 환경 격차를 정리하는 것이다.

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

최근 검증: [M2 새 폴더와 이름 변경](verification/m2/INCREMENT_03.md), [M2 휴지통 이동](verification/m2/INCREMENT_04.md), [M2 휴지통 복원 준비](verification/m2/INCREMENT_05.md), [M2 영구 삭제](verification/m2/INCREMENT_06.md), [M2 이동 기본 동선](verification/m2/INCREMENT_07.md), [M2 안전한 이동 실행 취소](verification/m2/INCREMENT_08.md), [M2 교차 볼륨 이동](verification/m2/INCREMENT_09.md), [M2 교체 백업과 실행 취소](verification/m2/INCREMENT_10.md), [M2 이동 취소와 진행 표시](verification/m2/INCREMENT_11.md), [M2 배치 이름 변경](verification/m2/INCREMENT_12.md), [M2 배치 이름 변경 패턴 UI](verification/m2/INCREMENT_13.md), [M2 네이티브 탭 기반](verification/m2/INCREMENT_14.md), [M2 탭 상태 및 세션 복원](verification/m2/INCREMENT_15.md), [M2 분할 pane 상태 모델](verification/m2/INCREMENT_16.md), [M2 AppKit 분할 탐색 UI](verification/m2/INCREMENT_17.md), [M2 활성 pane 파일 작업](verification/m2/INCREMENT_18.md), [M2 분할 workspace 세션](verification/m2/INCREMENT_19.md), [M2 보조 pane 감시·보기](verification/m2/INCREMENT_20.md), [M2 Finder 드래그 앤 드롭](verification/m2/INCREMENT_21.md), [M2 선택 항목으로 새 폴더](verification/m2/INCREMENT_22.md), [M2 안전한 복사 실행 취소](verification/m2/INCREMENT_23.md), [M2 폴더 병합 계획](verification/m2/INCREMENT_24.md), [M2 폴더 병합 실행](verification/m2/INCREMENT_25.md), [M2 폴더 병합 UI](verification/m2/INCREMENT_26.md), [M2 다중 선택 폴더 병합](verification/m2/INCREMENT_27.md), [M2 AppKit 통합 검증](verification/m2/INCREMENT_28.md), [M2 장애 주입](verification/m2/INCREMENT_29.md), [M2 실제 볼륨 매트릭스](verification/m2/INCREMENT_30.md), [M2 시스템 휴지통 왕복](verification/m2/INCREMENT_31.md).
