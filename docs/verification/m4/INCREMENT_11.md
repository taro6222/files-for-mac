# M4 열한 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 직접 열거 파일명 검색과 `NSMetadataQuery` Spotlight 콘텐츠 검색 adapter 분리
- 검색 패널의 파일 이름/Spotlight 콘텐츠 방법 선택
- 현재 폴더·하위 폴더, 종류, 숨김, 태그, 크기, 날짜 필터를 Spotlight 결과에도 동일 적용
- URL 표준화와 중복 제거, 128개 단위 부분 결과, 취소 시 query 중단
- 0건일 때 인덱싱 범위를 확인하도록 안내하여 직접 열거의 완전한 결과로 오인 방지

## 검증

- 전체 Swift 테스트 및 FilesMac 빌드: 93개 테스트 통과
- `searchRouterSeparatesEnumerationAndSpotlightAdapters`: 검색 방법별 adapter 분리 확인
- UI 자동 검증: 한국어/영어와 밝게/어둡게의 4개 조합 모두 통과
- `spotlightSearchCapability`: Spotlight 선택, query 종료, 전용 상태 문구 확인
- `search-spotlight.png`: 콘텐츠 검색 선택과 인덱스 범위 안내를 시각 확인

## 검증 한계와 남은 항목

- CI fixture의 Spotlight 인덱싱 시점은 결정론적이지 않아 실제 콘텐츠 hit는 자동 수용 조건으로 사용하지 않았다.
- 실제 사용자 볼륨에서 인덱싱 완료 파일, 인덱싱 제외 위치, 외장·네트워크 볼륨의 결과 차이를 별도 검증한다.
- 드라이브 장착·해제와 시스템 열기 기능을 계속 구현한다.

따라서 M4 완료로 표시하지 않는다.
