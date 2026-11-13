# M2 스물두 번째 개발 단위: 선택 항목으로 새 폴더

작성일: 2026-11-13

## 구현 내용

- 파일 메뉴와 목록 문맥 메뉴에 `선택 항목으로 새 폴더…`를 추가했다.
- 활성 pane의 현재 위치와 선택 항목을 고정한 뒤 새 폴더 이름을 입력받는다.
- 새 폴더는 기존 이름 검증·identity 확인·저널 기록을 사용하는 `EntryOperations.createFolder`로 만든다.
- 생성 성공 뒤 선택 항목을 기존 `MoveWindow`와 `EntryOperations.move`로 옮겨 동일/교차 볼륨 검증, 취소, 항목별 부분 실패, 실행 취소 기록을 그대로 제공한다.
- 새 폴더 이름 충돌과 잘못된 이름은 이동을 시작하기 전에 표시한다.
- 사용자가 작업 중 다른 pane으로 전환해도 완료 시 처음 선택한 pane 모델을 새로고침한다.

## 검증

- `DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`
- Swift Testing 69개 통과
- 새 메뉴·대화상자·비동기 생성/이동 연결을 포함한 `FilesMac` 앱 타깃 빌드 통과
- 새 폴더 저널·Unicode·이름 충돌과 이동·교차 볼륨·실행 취소 회귀 테스트 통과

## 제한 및 다음 단계

- 폴더 생성 이후 이동이 전부 실패하거나 취소되면 생성된 빈 폴더는 자동 삭제하지 않는다. 사용자가 만든 결과를 임의로 지우지 않고 작업 결과 창에서 상태를 확인하도록 한다.
- 여러 항목 이동은 전체 원자성이 아니며 성공·실패 항목이 함께 있을 수 있다.
- 템플릿 기반 파일 생성은 아직 제공하지 않는다.
- 다음 단계는 폴더/폴더 병합 정책과 복사 실행 취소를 구현해 M2 충돌·Undo 범위를 넓히는 것이다.
