# M5 쉰 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 상세 파일 목록에 Git index/work tree XY 상태 열 추가
- 저장소 하위 폴더에 변경 파일이 있으면 폴더 행에 집계 표식 표시
- 폴더 이동·재로딩 시 이전 작업 취소와 generation 기반 stale 결과 폐기
- 비동기 열 갱신 전후 선택 identity 보존
- 창 종료 시 Git subprocess 작업 취소
- 독립 clone fixture의 미추적 파일로 UI 검증을 작업 트리 상태와 분리

## 검증

- 전체 Swift Testing 153개 통과 및 FilesMac debug build 통과
- 한국어/영어 × 밝게/어둡게 UI 4조합 전체 통과
- 네 조합 모두 실제 local clone, 결정적 미추적 파일, Git 열 표시 확인
- 비동기 열 재로딩 뒤 다중 창 선택·Quick Look·히스토리 선택 보존 확인
- 저장소가 아닌 폴더와 Git 오류는 빈 상태로 fail-closed

## 남은 항목

- Git 열은 현재 기본 상세 보기에만 표시되며 보조 pane·그리드·목록·컬럼 표식은 미구현
- 큰 저장소의 가시 행 우선 조회와 공유 repository watcher 최적화
- 인증 HTTPS/SSH remote 실환경 검증
- submodule·LFS·hook 지원 경계 문서화 및 수용 결정

따라서 M5 Git 영역 완료로 표시하지 않는다.
