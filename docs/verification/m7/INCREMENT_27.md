# M7 Increment 27 — 60Hz 창 스크롤 갱신 간격

로그인된 macOS GUI에서 화면 기록 권한이 있는 터미널로 실행한다.

```sh
caffeinate -du -t 75 bash scripts/verify-scroll-window.sh
```

최적화 QA 앱이 빈 텍스트 파일 10,000개를 읽은 뒤 목록을 12pt씩 360회 스크롤한다. ScreenCaptureKit은 해당 프로세스의 시험 창만 캡처하며 이미지나 영상은 저장하지 않는다. 앱이 기록한 스크롤 구간에 도착한 완료 프레임의 샘플 표시 시각으로 간격을 계산한다. [Apple 프레임 상태 문서](https://developer.apple.com/documentation/screencapturekit/scframestatus)

Apple Silicon macOS 27.2 (26B123)의 60Hz 화면에서 6.396초 동안 완료 프레임 331개를 수집했다. 갱신 간격 p95는 33.41ms, 최댓값은 35.01ms였고 330개 간격 중 44개가 25ms를 넘었다. 화면이 절전 상태일 때의 실행에는 완료 표본이 없었다. [측정값](scroll-window-60hz.json)

캡처 간격에는 스크롤 입력 예약 간격과 캡처 지연이 포함될 수 있다. 이번 결과로 16.7ms 목표 충족을 확인할 수 없으며 Instruments의 공식 hitch 분류는 여전히 미측정이다.
