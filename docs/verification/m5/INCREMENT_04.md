# M5 네 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- ZIP 더블 클릭·열기, 파일 메뉴, 우클릭 메뉴에서 압축 탐색 패널 열기
- 내부 경로·종류·비압축 크기를 표형식 테이블로 표시
- 폴더 선택 후 기존 `ZipArchiveProvider` 사전 검증·staging·rollback 추출 경로와 연결
- 목록 읽기·추출 중 spinner, 중단 버튼, 완료·취소·실패 상태 표시
- 한국어/영어 및 라이트/다크 외형 적용

## 검증

- FilesMac 빌드 통과
- 전체 Swift Testing 103개 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과
- 각 조합에서 `archiveWindow`, `archiveListing`, `archiveExtraction` 검증값 모두 true
- Unicode·한글·이모지 경로 ZIP을 열고 추출한 파일의 payload가 `fixture`와 일치함을 실제 앱 흐름에서 확인
- 10,000항목 폴더 시나리오와 기존 탐색·검색·Quick Look·설정 회귀 체크 모두 통과

## 남은 항목

- 선택 항목으로 ZIP을 만드는 AppKit 생성 UI
- 스트림 byte·항목 기반 정량 진행률과 취소 수용 검증
- 보안 규칙 오류의 사용자 친화적 분류·해결 안내
- 암호 ZIP과 7z/RAR capability 표·실행 결과

따라서 M5 완료로 표시하지 않는다.
