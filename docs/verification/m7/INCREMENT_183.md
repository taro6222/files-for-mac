# M7 Increment 183 — Windows 원본 실행 화면 수집

수동 GitHub Actions 작업인 `Windows reference capture`는 Windows x64 러너에서 기준 소스 `99951c66928c4da714da8b1dd46039421182cbab`를 빌드한다. 원본의 릴리스 x64 패키지 생성 절차와 Windows App Runtime 버전을 따르고, 러너에서만 쓰는 인증서로 테스트 패키지를 설치한다. 설치 버전 4.2.9.0을 확인한 뒤 WinAppDriver로 앱을 실행한다.

첫 수집 대상은 UI-01 홈이다. 홈 위젯의 접근성 요소를 확인하고 창을 최대화한 뒤 PNG, UI Automation XML, 원본 커밋·패키지·화면 해시가 포함된 JSON을 시험 산출물로 저장한다. 러너 기본 환경에서 촬영하므로 동일한 테마·언어·창 크기에서 macOS와 비교하는 절차는 별도로 수행한다.

로컬 모의 드라이버에서 세션 생성, 홈 확인, 캡처 결과 생성 및 세션 종료가 통과했고 workflow YAML 구문도 확인했다. 실제 Windows 결과와 나머지 화면·상태 결과는 실행 후 기록한다.
