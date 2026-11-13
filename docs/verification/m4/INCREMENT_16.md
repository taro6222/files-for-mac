# M4 열여섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 최소·최대 파일 크기의 B/KB/MB/GB 단위 선택
- KB 이상에서 소수 입력을 바이트로 변환
- 음수·무한대·Int64 범위 초과 입력 거부
- 선택 단위를 최소·최대에 동일 적용하고 변환 뒤 범위 비교
- 태그·크기 행과 수정일 행을 분리해 900px 창에서 고급 필터 잘림 완화

## 검증

- 전체 Swift 테스트 및 FilesMac 빌드: 96개 테스트 통과
- `searchSizeUnitsConvertDecimalsAndRejectInvalidBounds`: 단위별 변환과 잘못된 경계 확인
- `searchSizeUnits`: 0.001~0.01KB가 1~10바이트로 변환되어 fixture 한 건을 반환
- UI 자동 검증: 한국어/영어와 밝게/어둡게의 4개 조합 모두 통과
- `search-advanced.png`: 두 줄 고급 필터, 단위 선택, 날짜 컨트롤과 결과를 시각 확인

## 남은 항목

- 실제 인덱싱 완료 콘텐츠의 Spotlight hit
- Quick Look 확장 본문 렌더링
- 실제 물리 외장 드라이브 추출

따라서 M4 완료로 표시하지 않는다.
