# M5 마흔세 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- Windows/IIS 계열 DOS LIST의 날짜·시간·`<DIR>`·크기 필드 판별
- DOS 목록의 공백 포함 파일·폴더 이름 보존과 폴더 metadata 전달
- 날짜형 상세 행이지만 크기/폴더 필드를 판별할 수 없으면 파일명으로 오인하지 않고 fail-closed
- 미지원 상세 목록 형식을 한국어·영어 원격 연결 오류로 안내
- 기존 Unix LIST·심볼릭 링크 제외·단순 이름 응답 호환 유지

## 검증

- Unix·DOS·단순 이름·Unicode·공백 포함 이름 parser 테스트 통과
- 모호한 DOS 상세 행의 `unsupportedListingFormat` 거부 테스트 통과
- 전체 Swift Testing 147개 통과
- 한국어/영어 × 밝게/어둡게 UI 4조합 기존 회귀 check 통과

## 남은 항목

- 공개 FTPS 서버 및 네트워크 단절·재시도 상태 검증
- 실제 Keychain UI 승인/거부와 장시간 credential 수명 점검
- SMB·클라우드 공급자별 실환경 수용

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
