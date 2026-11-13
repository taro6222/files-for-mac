# M3 첫 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 상세·목록·그리드·컬럼·적응형 보기 모드의 명시적 상태 모델
- 각 pane의 `TabSnapshot`에 보기 모드 저장
- 닫은 탭과 분할 workspace 세션을 통한 상태 보존 기반
- `viewMode` 필드가 없던 기존 저장 데이터의 상세 보기 호환 복원
- 위치를 다시 읽지 않고 보기 상태만 바꾸는 `BrowserModel` 동작

## 자동 검증

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFT_TMPDIR=/tmp \
swift test \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

결과: 81개 테스트 통과.

추가 확인 항목:

1. 그리드 보기 상태가 탭 세션 JSON 왕복 후 유지된다.
2. 기존 형식 JSON에서 `viewMode`가 없으면 `.details`로 복원된다.
3. 같은 보기 모드를 반복 설정해 불필요한 상태 변경 알림을 만들지 않는다.
4. 보기 모드 변경 시 현재 위치와 파일 열거 상태를 다시 읽지 않는다.

## 남은 항목

- AppKit 보기 전환 컨트롤과 메뉴
- 목록·그리드·컬럼 실제 렌더러
- 적응형 보기 정책과 사용자 수동 선택 우선 규칙
- 보기 전환 후 선택·스크롤·정렬 identity 유지 검증
- 화면별 시각 기준 및 한국어/영어·밝게/어둡게 검증

따라서 M3 완료로 표시하지 않는다.
