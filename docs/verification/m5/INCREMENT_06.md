# M5 여섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 생성·추출 provider에 planning/reading/writing/publishing 단계와 항목·바이트 진행 이벤트 추가
- 64KiB 스트리밍 루프에서 현재 경로와 누적 byte를 안전한 `@Sendable` callback으로 제공
- ZIP 생성·추출 작업 창에 항목 수, byte 수, 현재 경로와 determinate progress bar 표시
- 작업 완료 후 느린 진행 callback이 최종 성공·취소·실패 상태를 덮지 못하도록 차단

## 검증

- FilesMac 빌드 통과
- 전체 Swift Testing 104개 통과
- 256KiB 파일의 생성·추출 이벤트에서 항목·byte 수가 단조 증가하고 최종 publishing 이벤트가 1항목·262144 byte와 일치
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과
- 기존 ZIP 생성·목록·추출·10,000항목·검색·Quick Look 회귀 체크 모두 통과

## 남은 항목

- 보안 규칙·충돌·손상·원본 변경 오류의 사용자 친화적 분류·해결 안내
- 암호 ZIP과 7z/RAR capability 표·실행 결과
- 대용량 작업 취소의 실제 시간·임시 파일 수용 검증

따라서 M5 완료로 표시하지 않는다.
