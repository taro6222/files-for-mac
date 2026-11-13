# M5 열 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 생성·추출 API의 부모 Task 취소를 detached libarchive worker에 명시적으로 전파
- archive 목록 헤더 루프에도 취소 safe point 추가
- 64KiB 입출력 safe point에서 `CancellationError`로 종료하고 defer로 staging 정리
- 생성 작업 창 중단 버튼의 실제 Task 취소·상태 전환 검증

## 검증

- 16MiB source의 7z 생성을 스트리밍 중 취소: 1초 이내 `CancellationError`, 최종 archive 미생성, `.files-create-` 잔여 0건
- 동일 7z의 추출을 스트리밍 중 취소: 1초 이내 `CancellationError`, 공개된 항목 0건, `.files-extract-` 잔여 0건
- 전체 Swift Testing 108개 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과
- 각 조합에서 `archiveCreationCancellation` 및 기존 ZIP/7z/RAR·10,000항목 회귀 검증 모두 true

## 압축 하위 영역 판정

ZIP/7z 생성·탐색·안전 추출과 RAR 탐색·안전 추출은 현재 capability 범위에서 구현·검증했다. 암호·분할·archive update는 실제 fixture와 안전 재작성 정책이 없으므로 지원으로 표시하지 않는다.

M5 전체에는 클라우드·원격·Git 통합이 남아 있으므로 M5 완료로 표시하지 않는다.
