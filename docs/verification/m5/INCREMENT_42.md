# M5 마흔두 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 제품의 `ftps://`·기본 포트 990 계약과 같은 암시적 FTPS localhost fixture 추가
- 임시 로컬 CA와 SAN이 `localhost`·`127.0.0.1`인 정상 서버 인증서 생성
- 같은 CA로 서명했지만 SAN이 다른 불일치 서버 인증서 생성
- 테스트 전용 CA 파일 주입 지점을 curl config 표준 `cacert`에 연결
- credential·CA 경로를 command argument와 redacted description에 노출하지 않는 기존 stdin config 계약 유지

## 검증

- 정상 CA·호스트의 암시적 FTPS 목록과 Unicode 파일 다운로드 성공
- 동일 서버를 시스템 기본 신뢰만으로 연결할 때 신뢰되지 않은 인증서 거부
- 신뢰 CA가 같아도 호스트명이 다른 서버 인증서 거부
- 전체 Swift Testing 147개 통과
- FilesMac debug build 통과

## 남은 항목

- 비 Unix LIST 서버 capability·오류 안내
- 공개 CA를 사용하는 외부 FTPS 서버와 네트워크 단절·재시도 검증
- 실제 Keychain UI 승인/거부와 장시간 credential 수명 점검

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
