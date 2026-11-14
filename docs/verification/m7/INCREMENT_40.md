# M7 Increment 40 — 프리뷰 시작부터 메뉴 응답까지

```sh
python3 scripts/verify-preview-install.py --interactive-startup build/Files-macOS-preview.dmg
```

Apple Silicon macOS 27.2 (26B123)에서 `ca8c0d356f1d356359173f25417f8ba51f94f3c4`의 유니버설 프리뷰로 시험했다. DMG와 두 아키텍처의 앱 서명을 확인하고, 격리된 복사본을 별도 설정 도메인으로 ad-hoc 재서명했다. 실행 파일을 직접 시작해 테스트 폴더 창이 등록된 뒤, macOS 접근성 API로 해당 앱의 정보 메뉴 항목을 실행한다. 같은 PID에서 정보 패널 제목이 나타나면 성공으로 기록한다. 접근성 권한이 있는 데스크톱 세션에서 실행한다. [Apple 접근성 액션 API](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)

20회 새 프로세스의 시작부터 정보 패널 등록까지 p95는 **443 ms**, 첫 실행과 최댓값은 **734 ms**였다. OS 캐시는 공유했다. 측정값에는 probe 실행과 폴링 간격도 포함된다. 콜드 OS 캐시, Finder/Launch Services의 정식 배포 앱 시작, Gatekeeper 및 VoiceOver 사용자 동선은 추가 검증 대상이다. [20회 원시 표본](preview-interactive-startup-ca8c0d3.json)

같은 이미지에서 이전 버전 실행, 손상된 스테이징 복사본 거부, 정상 교체, 이전 앱 복원과 테스트 파일 보존도 통과했다. [설치·복원 결과](preview-install-ca8c0d3.json)
