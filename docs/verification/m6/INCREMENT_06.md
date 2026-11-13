# M6 여섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 선택 해제와 선택 반전 명령을 편집 메뉴·명령 팔레트에 추가
- 기본/보조 pane의 상세·그리드·목록·컬럼 보기에 동일 명령 연결
- 각 renderer에서 selection identity를 기준으로 선택을 교체하고 기존 상태 callback 유지

## 검증

- 전체 Swift Testing 153개 통과 및 FilesMac debug build 통과
- 한국어/영어 × 밝게/어둡게 UI 4조합 전체 통과
- 10,000개 상세 목록에서 2개 선택 후 반전 결과 9,998개 및 선택 해제 0개 확인
- 두 명령의 메뉴·명령 팔레트 catalog 등록 확인
- `scripts/audit-parity.py` 기준 명령 대응 상태 갱신

## 판정

`ClearSelection`, `InvertSelection`은 실제 구현과 UI 수용 증거가 생겼으므로 `implemented`로 전환한다. 남은 M6 대응 항목이 있으므로 전체 완료로 표시하지 않는다.
