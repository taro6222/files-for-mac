# M7 Increment 28 — 60Hz 스크롤 입력 방식 비교

최적화 QA에서 화면 갱신에 맞춰 스크롤하도록 `CADisplayLink` 경로를 추가했다. 15초 안에 시험이 끝나지 않으면 종료한다. 동일한 10,000항목 목록을 12pt씩 360회 이동하는 기존 타이머 경로도 비교에 사용했다. [Apple CADisplayLink 문서](https://developer.apple.com/documentation/QuartzCore/CADisplayLink)

```sh
caffeinate -du -t 140 bash -c 'bash scripts/verify-scroll-window.sh timer && bash scripts/verify-scroll-window.sh display'
```

Apple Silicon macOS 27.2 (26B123), 60Hz 화면에서 각 방식으로 한 번씩 실행했다. 화면 기록은 해당 시험 창의 프레임 간격만 저장했다.

| 입력 방식 | 스크롤 시간 | 완료 프레임 | 창 갱신 간격 p95 | 25ms 초과 간격 |
|---|---:|---:|---:|---:|
| 16ms 타이머 | 6.368초 | 333 | 33.23ms | 36/332 |
| 화면 동기화 | 6.009초 | 314 | 33.58ms | 36/313 |

화면 동기화로 스크롤 요청은 약 6초에 끝났지만 창 캡처의 p95는 약 33ms에 머물렀다. 이 표본으로 16.7ms 목표를 확인할 수 없다. 화면 구성 단계와 캡처 전달 단계 각각의 지연은 따로 확인해야 한다. [측정 결과](scroll-pacing-60hz.json)
