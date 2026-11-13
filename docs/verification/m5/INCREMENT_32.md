# M5 서른두 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 준비 gate를 통과한 SFTP 프로필에만 다운로드 명령 활성화
- 절대 원격 파일 경로 입력과 `NSSavePanel` 로컬 대상 선택
- 기존 로컬 목적지는 교체하지 않는 안전 다운로드 코어 호출
- 전송 중 진행 sheet와 명시적 취소 버튼 제공
- 취소를 subprocess 종료와 same-directory staging 정리에 전달
- 전송 중 trust·identity·목록·다운로드 중복 작업 차단
- 성공 시 최종 경로, 취소 시 staging 정리, 실패 시 오류 sheet 표시
- 좁은 폼에서 버튼이 겹치지 않도록 SFTP 작업 행과 Finder/저장 행 분리

## 검증

- 전체 Swift Testing 143개 통과
- FilesMac 빌드 통과
- 한국어/영어 × 라이트/다크 UI 4조합 모두 통과
- UI QA에서 trust/identity 없는 SFTP 프로필의 목록과 다운로드 명령 비활성 확인
- 기존 원격 연결 창, 최소 창 크기, SMB 연결, 목록·검색·압축 회귀 확인

## 남은 항목

- 실제 사용자 입력을 포함한 SFTP 다운로드 sheet 수동 수용 검증
- byte 단위 전송 진행률; 현재 subprocess 경계의 불확정 진행 표시만 제공
- 연결 결과를 탐색 pane provider로 통합
- host mismatch·연결 중단·대용량 취소 수용 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
