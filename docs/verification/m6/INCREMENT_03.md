# M6 세 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 선택·공유·생성·삭제·열기·이름 변경·휴지통 복원·복사 명령 12개 대응 판정
- 각 명령에 현재 AppKit selector/파일 작업 엔진 및 기존 수용 검증 증거 연결

## 검증

- `scripts/audit-parity.py` 통과
- 명령 202/202, identity 중복 0, 증거 누락 0
- 누적 `implemented` 28개, `awaiting-behavior-review` 174개
- 설정 143개와 화면 33개 상태 무변경

## 보수적 판정

- `CutItem`은 Finder식 잘라내기 command가 없으므로 이동 기능만으로 대응 처리하지 않았다.
- `Undo`는 이동/복사별 안전 Undo가 있지만 통합 Undo command가 아니므로 대응 처리하지 않았다.
- `ClearSelection`, `InvertSelection`은 명시적 command가 없어 대기로 유지했다.
- 정렬은 표 헤더 동작과 상태 저장이 있으나 원본 개별 command 대응이 없으므로 대기로 유지했다.

따라서 이름이 유사한 기능을 과대 매핑하지 않았으며 M6 완료로 표시하지 않는다.
