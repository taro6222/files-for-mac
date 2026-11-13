# M2 서른한 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- `FileManager.trashItem`을 사용하는 실제 macOS 시스템 휴지통 이동
- 휴지통에 생성된 실제 URL을 이용한 `restoreFromTrash` 복원
- 유니코드 파일명과 파일 내용 보존
- 일반 전체 테스트에서는 시스템 상태를 변경하지 않는 명시적 opt-in 검증 진입점

## 자동 검증

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-system-trash.sh
```

결과: 실제 시스템 휴지통으로 이동한 뒤 원래 바이트 내용으로 복원하는 집중 테스트 1개 통과. 고유한 사용자 캐시 fixture를 사용했으며 성공·실패와 관계없이 휴지통 잔여물과 fixture를 정리한다.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFT_TMPDIR=/tmp \
swift test \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

결과: 78개 테스트 통과.

## 확인된 동작

1. 유니코드 이름의 임시 파일이 실제 macOS 시스템 휴지통으로 이동한다.
2. 원본 경로는 사라지고 반환된 휴지통 URL에는 항목이 존재한다.
3. 휴지통 항목을 별도 복원 폴더로 복원한다.
4. 복원된 파일의 UTF-8 내용이 원본과 일치한다.
5. 기본 전체 테스트에서는 `FILES_TEST_SYSTEM_TRASH=1`이 없으면 외부 상태 변경을 건너뛴다.

## 남은 한계

- 이 검증은 코어 작업의 실제 시스템 통합을 확인하며 AppKit 메뉴 클릭 자체를 합성하지 않는다.
- 실제 SMB 네트워크 볼륨에서의 복사·이동·Undo와 이벤트 전달 차이는 아직 검증하지 않았다.
- M2 전체 완료로 표시하지 않는다.
