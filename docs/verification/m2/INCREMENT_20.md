# M2 스무 번째 개발 단위: 보조 pane 감시·보기 설정

작성일: 2026-11-13

## 구현 내용

- 보조 pane이 현재 위치별 독립 `DirectoryWatcher`를 생성하고 FSEvents 힌트가 오면 해당 `BrowserModel`만 다시 읽는다.
- 탐색 위치 변경과 pane 닫기·창 닫기 때 watcher task와 stream을 취소·정리한다.
- 초기 목록 로딩 중 외부 변경은 pending refresh로 합쳐 완료 직후 한 번 다시 읽는다.
- 보조 pane 도구막대에 숨김 항목 전환을 추가하고 pane별 `TabSnapshot.showHidden`에 저장한다.
- 이름·종류·크기 열의 정렬 descriptor를 연결하고 정렬 필드·방향을 pane별 세션에 저장한다.
- 감시 상태나 숨김·정렬 변경은 활성 pane 선택을 바꾸지 않는다.

## 검증

- `DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`
- Swift Testing 68개 통과
- 보조 pane watcher·정렬 delegate를 포함한 `FilesMac` 앱 타깃 빌드 통과
- 실제 임시 폴더 FSEvents 변경·watcher stop 회귀 테스트 통과
- 기존 탭/분할 세션과 파일 작업 회귀 테스트 통과

## 제한 및 다음 단계

- 보조 pane은 주 pane과 달리 감시 연결 실패 상태와 수동 재연결 버튼을 별도로 표시하지 않는다.
- 열 너비·순서 저장과 확장자 표시 설정은 주 pane의 전역 설정을 아직 공유하지 않는다.
- SMB·exFAT의 이벤트 전달 차이는 실제 볼륨 검증이 필요하다.
- 다음 단계는 Finder↔두 pane 드래그 앤 드롭, modifier별 복사/이동 정책과 실제 UI 통합 검증이다.
