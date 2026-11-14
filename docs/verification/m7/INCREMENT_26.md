# M7 Increment 26 — 스크롤 프레임 계측 시도

최적화 QA 실행에서 `FILES_PERFORMANCE_SCROLL=1`을 지정하면 파일 목록이 로드된 뒤 12pt씩 360회 스크롤한다. 일반 배포 빌드에는 이 계측 경로가 들어가지 않는다. 실행 결과에는 동작 횟수·거리·경과 시간을 남긴다.

macOS 27.2 (26B123), Apple Silicon, APFS에서 빈 텍스트 파일 10,000개로 시험했다. 직접 실행에서 4,320pt를 6.704초, 실행 중 AppKit 프로세스에 Instruments의 Animation Hitches를 연결한 시험에서는 4,320pt를 6.627초에 이동했다. 각 실행이 정상 종료했다.

Instruments 27.2 (27B52)의 해당 추적을 XML로 내보냈으나 `hitches`, `hitches-frame-lifetimes`, `hitches-updates`, `displayed-surfaces-interval`에 표본이 없었다. 앱에서 측정한 스크롤 경과 시간으로 화면 프레임 시간과 hitch 비율을 판정할 수 없어 16.7ms 검증은 미완료다.
