# M7 Increment 315 — 네이티브 탭의 잔여 메모리 증가 분리

상태: 원인 분리 실험이다. 제품 수정이나 장시간 안정성 통과로 집계하지 않는다. M7 출시는 미완료다.

Increment 313의 최근 기록 행 재사용 이후에도 남은 `NSKeyValueDependencyContext` 증가를 같은 최적화 QA 바이너리의 환경 설정만 바꿔 대조했다. 기준 소스는 `83a2a5b`이며 실험 수정은 별도 빌드 복사본에만 있다. 실제 제품의 탭·외형·테마 코드는 변경하지 않았다. [측정·소스·바이너리·원본 해시](native-tab-memory-investigation.json).

- 기본 닫기와 공개 `NSWindowTabGroup.removeWindow` 호출 후 닫기는 모두 5→40사이클에서 1,056→1,231개였다. 명시적 분리는 증가를 줄이지 못했다.
- 최초 탭 막대 표시 요청도 변화가 없었다. 기본은 5→40사이클에서 1,061→1,236개, 요청한 쪽은 6→41사이클에서 1,066→1,241개였다. 매 사이클 표시 상태를 검증한 실험은 아니다. 양쪽 모두 MallocStackLogging을 사용했으므로 일반 실행의 메모리 바이트와 직접 비교하지 않는다.
- 투명 제목 표시줄을 끈 대조도 양쪽 모두 5→40사이클에서 1,056→1,231개였다. 외형 변경을 제품에 적용할 근거가 없어 기본 설정을 유지한다.
- 복사 없는 탭/독립 창 대조의 5→40사이클에서 탭은 1,056→1,231개, 독립 창은 990→990개였다. 그러나 독립 창 실행은 62사이클에서 폴더 로딩 완료 대기 실패로 종료했다. 그 이전 힙 관측만 유효하며 독립 창 시험 전체 성공이나 장시간 안정성을 뜻하지 않는다.

모든 비교에서 관측 시점의 BrowserWindow·BrowserFileTable은 각각 한 개였다. 새 컨텍스트의 할당 스택에는 AppKit의 `computed_effectiveGlassMaterialContext`, 텍스트 필드 appearance 계산, 탭 버튼 삽입 경로가 있었다. 이는 할당 경로 증거이며 OS 결함의 확정이나 모든 보유 객체의 원인을 입증하지 않는다. 비공개 API나 SDK 메타데이터 변조는 제품에 적용하지 않았다.

`740ebf4`의 [macOS CI](https://github.com/taro6222/files-for-mac/actions/runs/45705238611)는 ARM·Intel 모두 Swift 시험 단계를 통과했다. 저장된 실제 태그 fixture와 새 읽기 시험이 포함된다. 두 Xcode 빌드도 성공했다. 전체 AppKit·설치 검증은 이 보고서 시점에 진행 중이며 전체 workflow 성공으로 표시하지 않는다.

별도 `5284cb3` 8시간 실행은 계속 유지한다. 최신 소스 장시간·잔여 증가 해결·Intel 성능·실제 접근성·전체 UI 상태 대조·정식 서명·공증 수용은 남아 있다. 사용자는 Developer ID 인증서와 notarytool 프로필이 준비 중이라고 확인했다. 준비된 것으로 간주하거나 동일 정보를 재요청하지 않는다.

재현은 기준 소스의 별도 복사본에 [진단 전용 패치](native-tab-memory-diagnostic.patch)를 적용하고 `swift build -c release --disable-sandbox -Xswiftc -DRELEASE_PERFORMANCE_QA`로 빌드한다. 각 프로세스는 별도의 `FILES_SOAK_DIRECTORY`, `FILES_SOAK_SECONDS=180`을 사용한다. 탭 분리 비교는 `FILES_SOAK_WORKLOAD=full`과 `FILES_SOAK_DETACH_BEFORE_CLOSE=0/1`, 제목 표시줄 비교는 `FILES_SOAK_WORKLOAD=tabs`와 `FILES_SOAK_OPAQUE_TITLEBAR=0/1`, 최초 탭 막대 비교는 `FILES_SOAK_WORKLOAD=tabs`·`MallocStackLogging=1`과 `FILES_SOAK_KEEP_TABBAR=0/1`이다. 독립 창 비교는 다른 옵션을 끄고 `FILES_SOAK_WORKLOAD=tabs/windows`를 사용한다. 보고서의 사이클을 확인해 5·40사이클 이후 `heap -s <owned-pid>`를 수집했다. 실행은 겹치는 호스트 부하가 있는 진단이며 처리량 비교가 아니다. [추출한 할당 경로](native-tab-memory-allocation-paths.txt).
