# M5 서른일곱 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- 네트워크와 개인키 없이 반복 가능한 AppKit 원격 pane fixture 추가
- 루트의 폴더·Unicode/공백 파일 행과 폴더/파일 종류 열 렌더링
- 폴더 선택 시 다운로드 비활성 확인
- 폴더 double-click과 뒤로·앞으로·상위 폴더 navigation 확인
- 파일 선택 시 다운로드 활성화와 정확한 원격 경로 callback 확인
- 원격 pane 캡처를 UI 검증 산출물에 추가

## 검증

- 한국어/영어 × 라이트/다크 UI 4조합 모두 통과
- `remoteBrowserRows`, `remoteBrowserFolderNotDownloadable`, `remoteBrowserNavigation`, `remoteBrowserDownloadSelection` 모두 true
- 각 조합의 `remote-browser.png` 생성
- FilesMac DEBUG 빌드 통과
- 기존 145개 Swift Testing 결과와 실제 OpenSSH 수용 결과 유지; 이번 단위는 FilesCore 변경 없음

## 남은 항목

- 원격 pane 경로·창 frame 세션 보존
- 키보드 Enter 열기, Delete 오작동 방지, VoiceOver label 확인
- 실제 SFTP 연결에서 pane 장시간 navigation 수용

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
