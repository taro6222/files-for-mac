# M4 열일곱 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 실제 macOS Spotlight 인덱스에서 Swift 소스 본문 검색
- Metadata Query가 지원하는 `LIKE[cd]` wildcard predicate 사용
- 사용자 홈·로컬 컴퓨터 인덱스 scope에서 수집한 결과를 요청 root로 후처리 제한
- `NSMetadataItemURLKey`가 없는 결과의 `NSMetadataItemPathKey` URL 복구
- 현재 폴더와 하위 폴더 scope 구분 유지

## 검증

- `mdfind`로 작업공간의 `SearchRouter` 콘텐츠 인덱스 존재를 독립 확인
- `spotlightContentHit`: 앱의 `NSMetadataQuery`가 `LocalSearch.swift`를 실제 결과로 반환
- 한국어/영어와 밝게/어둡게의 4개 UI 조합 모두 실제 콘텐츠 hit 통과
- 존재하지 않는 토큰은 요청 root 안에서 0건이며 Spotlight 전용 상태 안내 유지
- 전체 Swift 테스트 및 FilesMac 빌드: 96개 테스트 통과

## 수정 근거

기존 `CONTAINS[cd]` predicate는 `mdfind`와 `NSMetadataQuery`의 Spotlight query 문법에서 결과를 만들지 못했다. `LIKE[cd]`와 양쪽 wildcard로 변경한 뒤 동일 인덱스에서 5개 원시 결과를 수집하고 root·scope 필터를 거쳐 목표 파일을 반환했다.

## 남은 항목

- Quick Look 확장 본문 렌더링
- 실제 물리 외장 드라이브 추출

따라서 M4 완료로 표시하지 않는다.
