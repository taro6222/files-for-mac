# M4 여덟 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 정보 패널에서 쉼표로 구분하는 Finder 태그 편집
- 속성 로딩 완료 전 편집 비활성화와 단일 선택에서만 저장 허용
- 저장 후 resource value 재조회 및 정규화된 태그 표시
- 모든 태그 제거를 위한 빈 입력 지원
- 외부 파일 교체와 유효하지 않은 태그의 사용자 오류 표시
- 태그 xattr 변경 후 폴더 감시 자동 새로고침

## 자동 및 실제 UI 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 92개 테스트 통과. `DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 `fileInfoTags`를 포함한 모든 검사가 `true`였다.

정보 패널에서 `QA, 검토`를 저장한 뒤 별도 `FileTagService.snapshot`으로 두 태그를 다시 읽어 UI 내부 상태만이 아닌 실제 파일 resource value 변경을 확인했다. `file-info.png`에서 태그 편집 영역과 저장 완료 상태를 직접 확인했다. 태그 변경의 감시 debounce와 후속 히스토리 검증은 순차적으로 분리했다.

## 남은 항목

- Finder UI에서 앱이 쓴 태그의 색상·이름 직접 확인
- Finder에서 태그 수정 후 정보 패널 실시간 갱신
- 색상 index 표시·보존 정책
- 태그별 검색 필터

따라서 M4 완료로 표시하지 않는다.
