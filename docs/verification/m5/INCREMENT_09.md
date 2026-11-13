# M5 아홉 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- macOS 시스템 libarchive 7zip writer를 기존 다중 source 생성 provider에 연결
- 출력 확장자에 따라 ZIP/7z writer를 선택하고 RAR·알 수 없는 포맷 생성 거부
- 7z에도 source 링크/특수 항목 거부, 경로/크기 사전 검증, 64KiB 스트리밍, 원본 크기·수정 시간 재검증, 임시 완성 후 publish 적용
- 생성 명령·작업 창을 ZIP 전용 문구에서 압축 포맷 공통 문구로 갱신
- `NSSavePanel`에서 ZIP과 7z 확장자 허용

## 검증

- Unicode·이모지 중첩 폴더를 7z로 생성→재열기→안전 추출하고 payload 일치 확인
- 생성 후 `.files-create-` 임시 파일 잔여 0건
- 전체 Swift Testing 107개 통과
- `scripts/verify-ui.sh` 한국어/영어 × 라이트/다크 4조합 전체 통과
- 각 조합에서 `sevenZipCreation`, `sevenZipAndRarExtraction`, ZIP 생성·추출 및 기존 회귀 검증 모두 true

## 남은 항목

- 대용량 ZIP/7z 생성·추출 취소 지연·임시 파일 정리 수용 검증
- 암호·분할 압축은 실제 fixture 통과 전까지 미지원 유지
- archive update는 임시 archive 재작성·교체 정책 구현 전까지 미지원 유지

따라서 M5 완료로 표시하지 않는다.
