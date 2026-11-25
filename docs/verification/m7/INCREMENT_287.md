# M7 Increment 287 — 출시 검증 대기열 정리

같은 브랜치에 후속 커밋이 올라온 뒤에도 이전 자동 검증들이 대기열에 남아 있었다. 새 macOS 워크플로는 브랜치별 `push` 실행을 같은 동시성 그룹에 넣고 후속 실행이 이전 실행을 대체하도록 구성했다. 수동 실행과 PR은 실행 ID별 그룹을 사용한다. [GitHub 동시성 안내](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency)

현재 대기 상태를 다시 확인한 이전 커밋의 자동 실행 5개에 취소를 요청했다. 전체 AppKit 재시험 `45617289965`, Xcode 검증 `45618079399`, SMB 권한 검증 `45618354431`은 별도 수동 실행으로 추적한다.

수동으로 Xcode 빌드만 요청하면 추가 SwiftPM 전체 회귀 작업을 생략한다. 전체 AppKit 또는 업그레이드도 선택하면 해당 검증을 함께 실행한다. 워크플로 YAML과 변경 구문, 원본 대응표 감사를 확인했다. 실제 최신 자동 실행의 등록과 수동 검증의 계속 진행을 대조한다.
