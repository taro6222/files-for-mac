# M5 스물한 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 로컬 일반 파일만 FTP/FTPS 업로드 입력으로 허용
- 최종 원격 경로와 같은 부모에 무작위 `.files-upload-*.tmp` staging 이름 생성
- staging에 STOR 완료 후 postquote RNFR/RNTO로 최종 이름 publish
- 업로드·rename 실패 또는 취소 시 별도 DELE 명령으로 staging cleanup 시도
- 자격증명을 프로세스 인자와 진단 설명에 노출하지 않음
- 서버가 RNTO에서 기존 대상을 거부한다고 실제 검증한 capability가 없으면 업로드 실행 차단

## 검증

- FTPS upload-file, RNFR, RNTO, TLS 요구 명령 구성 확인
- cleanup DELE와 no-body 구성 확인
- arguments에 username·secret 부재 확인
- 상대 최종 경로 거부 확인
- 기본 capability에서 `unverifiedServerCapability`로 실행 전 차단 확인
- 전체 Swift Testing 127개 통과
- 한국어/영어 × 라이트/다크 UI 4조합 전체 회귀 통과

## 남은 항목

- fixture server에서 기존 대상 RNTO 거부 여부를 실제 probe하여 capability 발급
- 성공·실패·취소 후 원격 staging 잔존 여부와 최종 파일 내용 수용 검증
- 서버가 안전한 no-replace rename을 제공하지 않을 때 업로드 미지원 표시

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
