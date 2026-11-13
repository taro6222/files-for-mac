# M5 두 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- SwiftPM system library target으로 macOS 시스템 libarchive 직접 연결
- ZIP entry의 UTF-8 경로·종류·비압축 크기를 구조화 목록으로 변환
- 전체 entry 사전 검증 통과 후에만 추출 시작
- 대상 내부 hidden private staging에 regular file을 64KiB 단위 스트리밍
- 선언 크기와 실제 byte, 단일/총 크기 한도를 실행 중 재검증
- 링크·특수 항목 거부, 기존 top-level 대상 충돌 시 쓰기 전 중단
- 추출 완료 뒤 top-level publish, 중간 실패 시 이미 publish한 항목 rollback

## 검증

- 전체 Swift 테스트 및 FilesMac 빌드: 102개 테스트 통과
- Unicode·이모지 파일명과 payload의 목록·추출 왕복 통과
- 기존 대상 충돌 시 기존 내용 보존 및 staging 잔여물 0건
- 절대 경로를 가리키는 symbolic link archive 거부 및 대상 쓰기 0건
- 손상 ZIP 목록 실패, 선언 크기 한도 초과 시 대상 쓰기 0건
- 시스템 `ditto`가 생성한 실제 ZIP fixture를 libarchive provider로 읽고 추출

## 남은 항목

- ZIP 생성과 생성 결과 재열기 검증
- 취소·진행 UI 및 압축 목록·추출 창
- 암호 ZIP capability와 오류 구분
- 7z/RAR 읽기·추출 backend 결정

따라서 M5 완료로 표시하지 않는다.
