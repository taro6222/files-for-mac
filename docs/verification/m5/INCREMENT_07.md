# M5 일곱 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- ZIP/7z/RAR 포맷별 browse/extract/create/update/password/split capability 모델
- 실제 fixture로 통과한 ZIP 탐색·추출·생성만 지원으로 표시하고 나머지는 미지원으로 표시
- 앱 메뉴의 네이티브 압축 포맷 지원표
- 충돌, 손상/미지원, 위험 경로/항목, 크기 한도, 원본 변경/특수 항목, publish 실패의 한국어/영어 해결 안내

## 검증

- 전체 Swift Testing 105개 통과
- 확장자 대소문자 포맷 탐지와 capability 보수적 표시 테스트 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과
- 각 조합에서 `archiveCapabilitiesWindow` 및 기존 압축 생성·탐색·추출 검증값 모두 true

## 남은 항목

- 7z 생성·읽기·추출과 RAR 읽기·추출 backend/fixture
- 암호·분할 압축은 실제 fixture 통과 전까지 미지원 유지
- 대용량 취소 수용 검증

따라서 M5 완료로 표시하지 않는다.
