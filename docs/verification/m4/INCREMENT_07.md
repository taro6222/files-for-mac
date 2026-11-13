# M4 일곱 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- `URLResourceKey.tagNamesKey` 기반 Finder 태그 읽기
- 최소 지원 macOS 14에서 동작하는 `NSURL.setResourceValue` 기반 쓰기
- 앞뒤 공백 제거, 대소문자·발음 구별 기호를 무시한 중복 제거
- 빈 이름·255자 초과·개행 등 제어문자 차단
- 쓰기 전후 device·inode·생성일 identity 재검증
- 외부에서 같은 경로의 파일이 교체된 경우 쓰기 거부

## 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 92개 테스트 통과. 임시 파일에서 `Work`, `검토` 태그를 쓰고 다시 읽어 Finder resource value 왕복을 확인했다. 중복 정규화, 개행 태그 거부, 파일 삭제·재생성 후 이전 identity로 쓰기 거부를 검증했다.

## 남은 항목

- 정보 패널 태그 편집 UI와 오류 표시
- Finder에서 수정한 태그의 감시 갱신 및 앱에서 쓴 태그의 Finder 직접 확인
- 색상 index의 표시·보존 정책
- 태그별 검색 필터

따라서 M4 완료로 표시하지 않는다.
