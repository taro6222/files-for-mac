# M7 Increment 112 — 프리뷰 내장 설치·복구 안내

DMG의 릴리스 노트에 분할 패널 읽기 중단·재시도, Git 병합 충돌 표시, 로컬 SSH·HTTPS 인증 검증 범위와 복사·이동 실패 후의 복구 안내를 반영했다. 읽기 전용 마운트에서 Release Notes.txt가 저장소 문서와 일치하고 라이선스, 서명 및 두 아키텍처의 macOS 14.0 배포 대상이 유지되는지 확인했다.

앱은 e40f23a 소스를 사용했다. 이미지에 담긴 실행 파일의 SHA-256을 직전 프리뷰와 대조해 일치함을 확인했다. 앱 교체·복원은 실행 파일이 다른 3357ab6 프리뷰를 기준으로 검증했다. 파일과 설정을 유지하며 손상본 거부, 정상 교체, 이전 앱 복원이 통과했다. Apple Silicon에서 Launch Services로 실행한 20회의 정보 창 표시 p95는 523 ms였다. [설치 기록](preview-install-e40f23a-notes.json) · [기동 표본](preview-launch-services-e40f23a-notes.json)
