# M5 여덟 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- macOS 시스템 libarchive의 7zip, RAR4, RAR5 reader를 확장자별로 등록
- ZIP과 동일한 경로·링크·크기 사전 검증, hidden staging, publish/rollback 추출 경로 재사용
- 7z/RAR 더블 클릭·파일 메뉴·우클릭 메뉴 탐색·추출 연결
- capability 지원표를 7z/RAR browse/extract 지원, create/update/password/split 미지원으로 갱신

## 검증

- libarchive 공식 test suite의 7z empty-file fixture와 RAR no-EOF fixture를 출처·라이선스 안내와 함께 test resource로 고정
- 두 fixture의 구조화 목록, 신고 크기, 실제 추출 byte 일치 확인
- 전체 Swift Testing 106개 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과
- 각 조합에서 `sevenZipAndRarExtraction` 및 기존 ZIP·탐색·검색·10,000항목 회귀 검증 모두 true

## 남은 항목

- 7z 생성 provider/UI와 실제 재열기 검증
- 암호·분할 압축은 실제 fixture 통과 전까지 미지원 유지
- 대용량 취소 수용 검증

따라서 M5 완료로 표시하지 않는다.
