# M7 Increment 56 — 장시간 탐색의 메모리 증가 분석

Apple Silicon macOS 27.2 (26B123)의 장시간 탐색·복사·탭 시험에서 메모리 사용량이 계속 증가했다. 시험은 각 사이클에서 닫은 보조 탭과 디렉터리 감시 객체의 해제를 확인한다. 아래 수치는 동작 중인 프로세스의 힙 스냅샷으로, 전체 8시간 시험 결과가 아니다.

| 소스 커밋 | 실행 시작 후 대략적인 시간 | 물리 메모리 사용량 | `NSTableCellView` | `NSKeyValueDependencyContext` |
|---|---:|---:|---:|---:|
| `2be2717` | 6분 | 86.1 MiB | 612 | 40,769 |
| `aadc366` | 102분 | 530.0 MiB | 6,512 | 855,467 |

`heap --forkCorpse -s`로 계수를 수집했다. `leaks --forkCorpse --noContent --referenceTree`로 `2be2717` 프로세스를 살펴보니 AppKit의 `previousKeyViews`가 파일 목록 셀을, `BrowserFileTable`의 관찰 정보가 수만 개의 `NSKeyValueDependencyContext`를 보유했다. 같은 프로세스에서 일반 `leaks` 검사는 누수 0건을 보고했다. 따라서 이 증상은 도달 가능한 객체의 장시간 보유도 관찰해야 재현을 판정할 수 있다. 두 SOAK 바이너리의 소스가 다르므로 표의 수치를 단일 바이너리의 증가율로 계산하지 않았다.

목록 갱신 직후 AppKit에 키보드 포커스 경로 재계산을 요청한 실험에서는 약 26초, 66초, 134초의 힙 스냅샷에 각각 64개, 60개, 228개의 셀이 남았다. 같은 시점의 의존성 컨텍스트는 4,489개, 7,694개, 15,254개였다. 초기 수치가 낮아졌지만 객체 보유 문제가 해소됐다는 근거를 확보하지 못해 실험 변경을 제외했다. 장시간 메모리 기준은 계속 미충족 상태다. [AppKit 포커스 경로 API](https://developer.apple.com/documentation/appkit/nswindow/recalculatekeyviewloop%28%29)
