# M4 다섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 파일 메뉴와 명령 팔레트에서 접근 가능한 `⌘I` 정보 패널
- 단일 항목의 이름·위치·UTI·논리/할당 크기·날짜·소유자·그룹·권한·태그·볼륨·접근 상태
- 다중 선택 개수와 파일 크기 합계 요약
- 파일 SHA-256 계산, 진행 표시, 명시적 취소, digest 선택·복사
- 패널 닫기 및 새 항목 표시 시 이전 속성·해시 task 취소
- 폴더 해시 버튼 비활성화

## 자동 및 실제 UI 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 91개 테스트 통과. `DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 `fileInfoWindow`, `fileInfoHash`를 포함한 모든 검사가 `true`였다.

각 조합의 `file-info.png`를 생성했다. 한국어 다크 화면에서 전체 속성 행, 구분선, SHA-256 영역과 64자리 digest를 직접 확인했다. Swift 6 동시성 규칙에 맞춰 UI는 indeterminate 진행 표시를 사용하고, 처리 바이트 진행 콜백은 코어 API에 유지했다.

## 남은 항목

- Quick Look 미리보기와 포맷별 로딩·실패 상태
- Finder 태그 쓰기·색상·Finder 왕복
- 해시 실행 중 파일 변경 전후 identity 재검증
- 속성 편집 및 ACL 상세 표시

따라서 M4 완료로 표시하지 않는다.
