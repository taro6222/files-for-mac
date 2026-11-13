# M5 마흔 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- FTP/FTPS 목록을 NLST 파일명 전용 응답에서 Unix LIST metadata 응답으로 전환
- mode 첫 문자의 `d`로 폴더, `-`로 일반 파일 판정
- 공백·Unicode 이름을 9번째 필드 이후 전체로 보존
- 심볼릭 링크는 대상 ambiguity와 탈출 위험 때문에 탐색 목록에서 제외
- 단순 파일명 fixture도 이전 호환 형식으로 계속 해석
- 폴더 metadata를 공통 `RemoteDirectoryEntry`로 전달해 원격 탐색 모델에서 사용 가능

## 검증

- 공백 포함 폴더·파일과 링크 제외 parser 테스트 통과
- 실제 localhost pyftpdlib + curl에서 `fixture-folder` 디렉터리 판정 통과
- 실제 Unicode 파일 목록·다운로드·rename capability probe 통과
- 전체 Swift Testing 146개 통과
- 이번 단위는 AppKit UI 변경 없음; 기존 UI 4조합 결과 유지

## 남은 항목

- FTP/FTPS 프로필과 Keychain credential을 AppKit 원격 pane에 연결
- 비 Unix LIST 서버 capability·오류 안내
- FTPS 인증서 정상·불일치 실제 수용 검증

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
