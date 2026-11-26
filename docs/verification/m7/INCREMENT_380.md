# 380 — 원격 Swift 6.2 UI 검증 컴파일 오류 수정

최신 b41087a의 [45878584565](https://github.com/taro6222/files-for-mac/actions/runs/45878584565) ARM 작업은 Debug 빌드에서 실패했다. 종료된 job의 로그 API와 build artifact를 보존했다. 컴파일러는 `ArchiveEditingUIVerification.swift`의 124/128/133행에서 `&&` 우측의 throwing 파일 읽기에 대해 ‘operator can throw but expression is not marked with try’를 보고했다. 실제 환경은 원격 Xcode 26.3/Swift 6.2.4, 로컬 CLT Swift 6.4.2였다.

세 파일/목록 읽기를 불리언 식 앞의 별도 `try` 문장으로 옮겼다. 오류는 그대로 전파하고 검사값은 같은 읽기 결과로 비교한다. 실패를 무시하거나 조건을 제거하지 않았다. 편집 검증 37개의 키/순서와 전체 369개 조건을 유지한다. 변경 파일 전체가 DEBUG 조건 안이므로 Release 앱 코드·SDK·Core·데이터 정책은 바뀌지 않는다.

로컬 Debug 9.84초 빌드, 기존 검사 키/순서 비교와 diff 공백 검사를 통과했다. 이 결과가 원격 Swift 6.2.4 컴파일이나 UI 성공을 증명하지는 않는다. Core/Release가 변경되지 않아 앞서 통과한 379의 74개와 Release 검증을 반복하지 않았다. 로컬 GUI/장시간 앱은 실행하지 않았다.

앞선 d2f9eff의 [45877111686](https://github.com/taro6222/files-for-mac/actions/runs/45877111686)는 그대로 유지한다. 관찰 시 ARM은 SDK용 Release 준비 빌드 후 실제 전체 UI 단계에 진입했고 Intel은 분리된 준비 빌드 중이었다. b41087a의 Intel도 기존 실행을 유지했으며 결과 없이 성공으로 집계하지 않는다. 이번 수정 소스의 원격 컴파일·실제 UI·최종 F23/M7 수용은 미완료다. [소스·컴파일 진단 기록](archive-ui-compiler-380.json).
