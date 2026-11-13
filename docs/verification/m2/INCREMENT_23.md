# M2 스물세 번째 개발 단위 검증 — 안전한 복사 실행 취소

검증일: 2026-11-13

## 구현 범위

- 성공적으로 게시된 복사 결과의 파일 시스템 identity와 전체 내용 snapshot을 작업 저널에 기록한다.
- 가장 최근 복사 작업을 찾아 실행 취소할 수 있는 별도 undo 저널을 저장한다.
- 실행 취소 시 identity와 snapshot이 모두 동일한 앱 생성 결과만 삭제한다.
- 복사 뒤 수정·교체·삭제된 항목은 외부 변경으로 간주해 보존하고 항목별 결과를 보고한다.
- 편집 메뉴에서 확인 대화상자, 양쪽 pane 새로고침, 부분 실패 상세 결과를 제공한다.

## 자동 검증

명령:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp \
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

결과: 70개 테스트 통과. 새 테스트는 변경되지 않은 복사 결과가 삭제되고, 복사 뒤 내용이 변경된 결과는 보존되며, undo 기록이 소비되는지 검증한다. 이 명령은 `FilesMac` 실행 파일도 함께 빌드했다.

## 안전성 판단

- 경로 이름만으로 삭제하지 않고 게시 직후 `st_dev`, `st_ino`, 파일 형식과 전체 snapshot을 다시 확인한다.
- 조건이 하나라도 달라지면 삭제하지 않으므로 외부 프로그램의 변경을 덮지 않는다.
- undo 결과를 별도 JSON으로 남기며 원본 undo 기록은 한 번만 소비한다.

## 남은 항목

- Finder/AppKit 실제 창에서 확인 대화상자와 부분 결과 표시를 수동 검증해야 한다.
- 대형 디렉터리 snapshot 비용과 네트워크 볼륨 identity 안정성은 실제 APFS/exFAT/SMB fixture에서 측정해야 한다.
- 폴더 병합 충돌 정책은 다음 개발 단위이며, M2 전체 완료로 표시하지 않는다.
