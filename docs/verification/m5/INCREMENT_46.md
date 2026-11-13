# M5 마흔여섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 같은 base에서 local·peer가 서로 다른 commit을 만든 divergent branch fixture
- fetch 뒤 ahead 1·behind 1 상태 확인
- `pull --ff-only` 실패를 명시적 command failure로 유지
- 실패 전후 HEAD SHA 동일성 확인
- 실패 뒤 local 작업 파일 내용 보존 확인
- reset·clean·자동 merge를 호출하지 않는 계약 검증

## 검증

- local bare remote 기반 divergence 수용 검증 통과
- pull 실패 뒤 HEAD와 작업 파일 byte 내용 보존 통과
- 전체 Swift Testing 152개 통과
- FilesMac debug build 통과

## 남은 항목

- 장시간 Git 작업 취소·subprocess와 clone staging 정리
- Git AppKit 패널과 파일 목록 상태 열 연결
- 인증이 필요한 HTTPS/SSH remote 실환경 검증

따라서 M5 Git 영역 완료로 표시하지 않는다.
