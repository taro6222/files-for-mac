# M2 스물한 번째 개발 단위: Finder 드래그 앤 드롭

작성일: 2026-11-13

## 구현 내용

- 주 pane과 보조 pane의 파일 행을 표준 `NSURL` pasteboard writer로 내보낸다.
- Finder와 앱의 다른 pane에서 전달된 파일 URL을 현재 폴더 또는 drop한 하위 폴더 대상으로 받는다.
- 기본 drop은 복사, Option은 복사, Command는 source가 이동을 허용할 때 이동으로 해석한다.
- Option과 Command가 함께 눌리면 데이터 손실 위험이 낮은 복사를 우선한다.
- 이동을 허용하지 않는 외부 source가 Command와 함께 drop돼도 복사로 낮춘다.
- 실제 실행은 기존 `CopyEngine`·`EntryOperations.move`와 충돌 정책 대화상자를 사용하므로 descendant·충돌·검증·취소 안전 규칙을 우회하지 않는다.

## 검증

- `DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`
- Swift Testing 69개 통과
- 양쪽 pane의 pasteboard writer·drop delegate를 포함한 `FilesMac` 앱 타깃 빌드 통과
- modifier 없음/Option/Command/복합 modifier/이동 불가 source의 intent 단위 테스트 통과
- 기존 교차 볼륨 이동·descendant 거부·충돌 경쟁·취소 회귀 테스트 통과

## 제한 및 다음 단계

- Finder 실제 drag session의 modifier 표시와 cursor badge는 수동 UI 검증이 남아 있다.
- file promise와 비파일 URL·텍스트 drop은 아직 지원하지 않는다.
- 드래그 중 대상 폴더 hover 자동 열기와 edge 자동 스크롤은 AppKit 기본 범위만 사용한다.
- 다음 단계는 실제 Finder↔앱↔pane 통합 검증, 세션 재실행 검증, M2 수용 기준 격차 문서화다.
