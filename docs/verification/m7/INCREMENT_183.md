# M7 Increment 183 — Windows 원본 실행 화면 수집

수동 GitHub Actions 작업인 `Windows reference capture`는 Windows x64 러너에서 기준 소스 `99951c66928c4da714da8b1dd46039421182cbab`를 빌드한다. 원본의 릴리스 x64 패키지 생성 절차와 Windows App Runtime 버전을 따르고, 러너에서만 쓰는 인증서로 테스트 패키지를 설치한다. 설치 버전 4.2.9.0을 확인한 뒤 WinAppDriver로 앱을 실행한다.

첫 수집 대상은 UI-01 홈이다. 홈 위젯의 접근성 요소를 확인하고 창을 최대화한 뒤 PNG, UI Automation XML, 원본 커밋·패키지·화면 해시가 포함된 JSON을 시험 산출물로 저장한다. 러너 기본 환경에서 촬영하므로 동일한 테마·언어·창 크기에서 macOS와 비교하는 절차는 별도로 수행한다.

로컬 모의 드라이버에서 세션 생성, 홈 확인, 캡처 결과 생성 및 세션 종료가 통과했고 workflow YAML 구문도 확인했다. 실제 Windows 결과와 나머지 화면·상태 결과는 실행 후 기록한다.

[첫 Windows 실행](https://github.com/taro6222/files-for-mac/actions/runs/43652157860)에서 고정 원본 빌드와 4.2.9.0 패키지 설치가 통과했다. 설치한 MSIX 번들의 SHA-256은 `36519ca95c0178d460aad28c609eb8519f4a3bb08ae14cafb0f16523cf1b9266`이다. WinAppDriver 세션은 열렸고 홈 판정은 제한 시간을 초과했다.

홈 확인을 원본에서 위젯에 직접 지정한 영어 접근성 이름 `Drives`와 `Network locations`로 수정했다. [WinAppDriver API](https://github.com/microsoft/WinAppDriver/blob/master/Docs/SupportedAPIs.md)의 현재 창 최대화 경로를 사용한다. 판정에 실패하면 마지막 창의 트리와 스크린샷을 진단용 이름으로 저장한다. 모의 드라이버에서 홈 판정, 시작 화면 거부, 진단 파일 생성, 세션 정리를 확인했다.

[두 번째 Windows 실행](https://github.com/taro6222/files-for-mac/actions/runs/43653279723)도 빌드와 설치를 통과했다. WinAppDriver의 앱 시작 요청은 프로세스 ID를 얻었으나 창을 찾지 못해 HTTP 500으로 끝났다. 이제 Windows 셸에서 설치한 패키지를 시작하고, 그 패키지의 `Files.exe`가 제목 있는 창을 내놓으면 [WinAppDriver의 창 핸들 연결](https://github.com/microsoft/WinAppDriver/blob/master/Docs/AuthoringTestScripts.md#supported-capabilities)을 사용한다. 창이나 세션을 얻지 못한 실패도 진단 텍스트로 저장한다. 모의 드라이버에서 핸들 연결 요청, 화면 저장, 연결 실패 기록을 각각 확인했다.

창 핸들 방식으로 [실제 홈 캡처 및 대조](INCREMENT_189.md)를 완료했다.
