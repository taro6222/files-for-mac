# M5 마흔한 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- FTP/FTPS 프로필에 전용 AppKit `FTP/FTPS 탐색` 동작 연결
- Keychain credential이 없는 프로필의 연결 버튼 비활성화
- 목록을 열 때와 폴더를 이동할 때마다 credential을 Keychain에서 다시 읽어 장기 보관 방지
- 공통 원격 pane에서 폴더 이동·뒤로·앞으로·상위·새로 고침·중단 제공
- 선택한 일반 파일을 안전한 FTP/FTPS 다운로드 publish 경로에 연결
- 프로필별 마지막 원격 경로와 창 frame 복원
- SFTP와 FTP/FTPS 전송을 공통 단일 작업 상태로 직렬화

## 검증

- 전체 Swift Testing 146개 통과
- FilesMac debug build 통과
- 한국어/영어 × 밝게/어둡게 UI 4조합 통과
- 네 조합 모두 `ftpCredentialGate`, 원격 pane 탐색·다운로드 선택·폴더 차단·접근성 및 기존 회귀 check 통과
- 기존 localhost FTP 상세 목록·다운로드·rename capability 검증은 146개 전체 테스트에 포함

## 남은 항목

- FTPS 정상 인증서·불일치 인증서·TLS 실패 실제 수용 검증
- 비 Unix LIST 서버의 capability·오류 안내
- 실제 Keychain UI 승인/거부와 장시간 credential 수명 점검

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
