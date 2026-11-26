# M7 Increment 323 — 앱 코드 없는 네이티브 탭 메모리 재현

상태: 독립 진단 빌드·세 차례 창/탭 반복·Python/YAML 검사 완료. 제품 수정·메모리 안정성 통과·M7 출시 완료로 집계하지 않는다.

기존 측정에서 브라우저 탭을 열고 닫을 때 남은 `NSKeyValueDependencyContext` 증가가 관측됐다. 이번 재현은 FilesCore·BrowserWindow·파일 목록·최근 기록·파일 작업을 모두 제외하고 AppKit만 import하는 독립 실행 파일을 사용한다. 실제 제품 코드는 바꾸지 않았다.

동일한 제목 표시줄·크기의 창에서 독립 창과 네이티브 탭을 비교한다. 탭은 실제 두 창의 부착을 확인하고 독립 창은 탭 그룹에 합쳐지지 않았는지 확인한다. 보조 창을 생성·표시·즉시 닫은 뒤 autorelease pool을 비우고 weak 참조 해제를 기다린다. 다음 사이클 전 50ms를 대기한다. 5·40·400사이클마다 실행을 멈춰 소유 프로세스의 `heap -s`를 수집하므로 관측 중 사이클이 변하지 않는다.

검증기는 실제 런타임 클래스의 기준 창 한 개와 보조 창 해제를 요구한다. 내부 클래스가 해당 OS에 없으면 0이 아닌 null로 기록한다. 진단 완료는 힙 증가가 없다는 뜻이 아니며 결과에 `productChanged: false`, `stabilityGatePassed: false`를 기록한다. 계수는 물리 메모리 바이트나 제품 전체 증가량으로 환산하지 않는다. 즉시 닫는 작은 재현과 실제 브라우저의 객체 증가 속도도 직접 비교하지 않는다.

[독립 Swift 재현](../../../scripts/diagnostics/NativeTabMemoryProbe.swift)과 [측정기](../../../scripts/diagnostics/verify-native-tab-memory.py)는 별도 임시 출력 폴더를 요구한다. macOS 15의 Apple Silicon·Intel용 [수동 진단 workflow](../../../.github/workflows/native-tab-memory.yml)는 같은 재현을 빌드하고 결과·힙·바이너리·실제 SDK/최소 대상과 소스/바이너리 해시를 보존한다. SDK와 런타임이 모두 다른 비교만으로 OS 차이라고 결론 내리지 않는다. 원격 바이너리를 같은 런타임에 가져와 비교할 근거를 남긴다.

로컬 재현 예시는 다음과 같다. 출력 폴더는 기존 결과를 덮어쓰지 않는다.

```sh
task_probe_root="$(mktemp -d /tmp/files-native-tab.XXXXXX)"
DEVELOPER_DIR=/Library/Developer/CommandLineTools xcrun swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$task_probe_root/ModuleCache" \
  scripts/diagnostics/NativeTabMemoryProbe.swift -o "$task_probe_root/NativeTabProbe"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 scripts/diagnostics/verify-native-tab-memory.py \
  --binary "$task_probe_root/NativeTabProbe" --output "$task_probe_root/results"
```

[Undo 커밋 `28f8020` 원격 최종 결과](overlapping-undo-28f8020-ci-final.json)는 전체 workflow 성공이다. 두 CPU 전체 AppKit·프리뷰 교체/복원과 두 Xcode 빌드가 성공했고 최적화 성능 작업은 실행하지 않았다. [이동 커밋 `7651b8f` 관측 결과](move-selection-7651b8f-ci-progress.json)는 두 Xcode 성공과 전체 검증 진행 상태를 별도로 보존한다. 이 성공만으로 이전 Intel ACL 실패 원인이 확정되거나 최신 소스의 장시간·성능 게이트가 통과한 것은 아니다.

기존 `5284cb3` 8시간 프로세스는 이 단계 시작 시 실제 PID 71382의 실행을 확인했다. 당시 약 5.45시간·6,498사이클이며 재시작하지 않았다. 최신 제품 소스 8시간, 메모리 증가 해결, 지원 환경·외부 서비스·실제 접근성·원본 전체 UI 상태 대조·정식 서명·공증 수용은 남아 있다. 인증서와 공증 프로필은 사용자 준비 중이다.

최종 로컬 관측은 세 번 모두 일치했다. 독립 창의 컨텍스트는 5·40·400사이클 각각 104개였고 탭은 413·1,113·8,313개였다. 각 관측 시 실제 기준 창은 한 개, 최종 보조 창 해제는 400개다. 현재 조합은 SDK 27.2·최소 대상 14.0·macOS 27.2.1 arm64다. 40사이클 이후에도 400사이클까지 증가했지만 영구적으로 무한 증가한다는 증명은 아니다. 제품의 기존 5개/사이클 증가와 이 즉시 닫기 재현의 20개/사이클 증가가 같은 전체 원인이라고 확정하지 않는다. [최종 소스·바이너리·18회 힙 관측 해시](native-tab-minimal-reproduction.json).

제품 Sources·Package·Xcode 프로젝트에 차이가 없음을 확인했으며 제품 빌드·전체 UI 시험은 이번 진단 단위에서 반복하지 않았다. 새 원격 진단 실행과 제품 메모리 안정성 해결은 아직 완료되지 않았다.
