# M5 세 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 파일·폴더 다중 source를 하나의 ZIP으로 생성
- URL path component 기반 상대 경로로 Unicode 정규화 형태와 무관한 경로 구성
- source symlink·특수 항목, 중복 source, 기존 archive 대상 거부
- source 목록을 먼저 고정하고 security validator로 생성 경로 재검증
- 파일을 64KiB 단위로 libarchive writer에 스트리밍
- 기록 전후 파일 크기·수정 시각 재검증으로 생성 중 원본 변경 차단
- 같은 디렉터리의 hidden 임시 archive를 완성한 뒤 최종 경로로 publish

## 검증

- 전체 Swift 테스트 및 FilesMac 빌드: 103개 테스트 통과
- Unicode·이모지 중첩 폴더와 독립 파일을 생성→목록 재열기→안전 추출해 payload 일치 확인
- macOS NFD/NFC 차이는 canonical-equivalent 경로로 확인하고 archive spelling은 보존
- 기존 archive가 있을 때 내용 보존, symlink source 거부, 임시 archive 잔여물 0건
- Unicode 경로를 문자열 offset으로 잘라 중복 component가 생기던 결함을 `DirectoryEnumerator.level` 기반 component 계산으로 수정

## 남은 항목

- 압축 목록·생성·추출 AppKit UI
- 진행·취소와 사용자 오류 분류
- 암호 ZIP과 7z/RAR capability

따라서 M5 완료로 표시하지 않는다.
