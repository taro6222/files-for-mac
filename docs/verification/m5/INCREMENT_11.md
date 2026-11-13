# M5 열한 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- `~/Library/CloudStorage` 아래의 보이는 공급자 폴더와 iCloud Drive 위치 탐지
- Dropbox/OneDrive 등 `Provider-account` 폴더명에서 공급자 이름을 보수적으로 분리하고 중복 표준 경로 제거
- ubiquitous resource value로만 offline 사용 가능, online-only, downloading, uploading, conflict, error 상태 판정
- 상태 metadata가 없는 일반 File Provider 위치는 `unknown`으로 유지
- 위치 사이드바에 클라우드 위치를 비동기로 표시하고 기존 탐색 모델로 열기

## 검증

- iCloud·Dropbox·OneDrive fixture 폴더 3개 탐지, 숨김 폴더·일반 파일 제외, 공급자명·정렬 확인
- ubiquitous metadata가 없는 fixture 3개 모두 `unknown`으로 유지하여 가짜 동기 완료 표시 방지
- 없는 root에서 빈 결과·`unknown` 상태 반환
- 전체 Swift Testing 110개 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과
- 각 조합에서 `cloudLocations` 3개·unknown 상태와 기존 회귀 검증 모두 true

## 남은 항목

- iCloud ubiquitous 항목 다운로드·오프라인 유지·공간 비우기 명령과 상태 갱신
- 실제 설치된 공급자별 로컬·online-only·오프라인 수용 검증
- File Provider 전용 상태 API가 없는 공급자에 대해 상태를 추정하지 않음

따라서 M5 클라우드 영역 완료로 표시하지 않는다.
