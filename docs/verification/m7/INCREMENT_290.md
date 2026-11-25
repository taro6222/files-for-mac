# M7 Increment 290 — Git 프로세스 대기와 SMB 권한 오류 검증

[macOS 15 전체 AppKit 실행](https://github.com/taro6222/files-for-mac/actions/runs/45617289965)은 실패했다. Intel은 한국어 밝은 테마에서 180초 제한에 도달했고 한국어 어두운 테마의 폴더 크기 두 검사가 실패했다. 영어 두 테마는 각각 283개를 통과했다. Apple Silicon은 네 테마·언어 조합 모두 시간 제한에 도달했다. [결과와 스택 요약](appkit-86be2b0-ci-failures.json)

Apple Silicon의 네 스택에서 Git 프로세스의 DispatchGroup 대기가 Swift 작업 스레드를 차지했고 메인 이벤트 루프는 대기 중이었다. Git의 `Task.detached` 안에서 동기 프로세스·파이프를 기다리는 구조를 checked continuation과 GCD 작업으로 바꿨다. 취소 처리와 Git의 인자·출력 검증은 기존 경로를 유지한다. 로컬 단일 협력 풀 검사에서는 수정 전 정체를 재현하지 못했으므로 이 변경이 원격 시간 초과를 해결했다고 판정하지 않는다.

32개 동시 Git 상태 조회와, 외부 프로세스가 기다리는 동안 Swift 호출자가 재개되는 검사를 추가했다. CI는 제한된 Swift 협력 풀에서 이 두 검사와 기존 clone 취소 검사를 실행한다. Intel 폴더 크기 검사에는 목록 준비·항목 수·자동 계산 바이트·대기 작업·버튼 상태·요청 결과 진단을 추가했다. 180초 전체 제한과 폴더 크기 5초 제한은 유지했다.

별도의 [SMB 3.1.1 실마운트 실행](https://github.com/taro6222/files-for-mac/actions/runs/45618354431)은 소스 `8d504b8f3a00d58bcb42bd35e8118802e4cb0c9b`에서 7개 시험을 통과했다. 신규 `mountedSMBServerRevokesStagingWritePermission`은 서버의 임시 출력 폴더를 `0500`으로 변경한 뒤 이동 실패, 원본·기존 대상 보존, 임시 출력 제거 및 실행 취소 기록 부재를 확인했다. 나머지 복사·이동·실행 취소, 읽기 전용 공유, 시각 보존과 세 가지 재연결 검사도 통과했다.

[수정된 네이티브 Xcode 빌드](https://github.com/taro6222/files-for-mac/actions/runs/45621040066)는 소스 `466f5bdb0893001a503c101dc96c363a8aff507d`에서 Apple Silicon·Intel 모두 통과했다. 앱 실행 파일과 명시적 Info.plist의 preview 채널도 통과했다.

전체 앱·테스트 빌드, 제한된 Swift 협력 풀의 Git 관련 13개 시험, 대응표 구조 감사와 CI YAML 구문 검사가 통과했다. 최종 앱은 한국어·영어 × 밝게·어둡게 네 조합에서 각각 283개 AppKit 검사를 통과했다. 폴더 크기 진단은 네 조합 모두 목록 준비, 10,000개 항목, 자동 계산 21바이트와 버튼 요청 완료를 확인했다. [원본 보고서·실행 파일 및 소스 해시](git-scheduling-macos27.2.1.json)

수정 후 macOS 15의 Apple Silicon·Intel 전체 AppKit 실행으로 원격 시간 초과 해결 여부를 판정한다. 8시간 시험은 계속 진행 중이다. Developer ID와 공증 프로필은 사용자 답변에 따라 준비 중이며, 서명·공증 게이트는 열린 상태다.
