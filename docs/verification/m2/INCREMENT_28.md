# M2 스물여덟 번째 개발 단위 검증 — AppKit 통합 fixture

검증일: 2026-11-13

## 추가한 검증 경로

`scripts/verify-m2-ui.sh`는 DEBUG 앱을 실행하고 사용자 파일과 Application Support를 사용하지 않는 격리 fixture에서 다음을 검사한다.

- 누락 파일 복사, 기존 폴더 재귀 병합, 파일 충돌 보존을 한 배치로 실행
- 실제 BrowserWindow 목록에 복사 결과 반영
- 수직 분할 workspace 생성
- 편집 메뉴의 복사 Undo action과 격리 저널 기준 활성화 판정
- 작업 단위 Undo 후 목록 갱신, 병합 전 기존 파일 보존
- 병합·분할 및 Undo 후 화면 PNG 생성

## 실행 결과

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools ./scripts/verify-m2-ui.sh
```

한국어/영어 × 밝음/어두움 4조합에서 각 10개 검사가 모두 통과했다. 산출물은 Git에서 제외된 `build/m2-ui-verification/`에 생성된다.

기존 `scripts/verify-ui.sh`도 같은 HEAD에서 한국어/영어 × 밝음/어두움 4조합의 탐색·오류·다중 창·감시 검사를 모두 통과했다. 전체 Swift Testing 74개도 재통과했다.

## 검증 경계

- QA 훅은 실제 AppKit 창과 목록을 사용하지만 사용자 클릭을 합성하는 XCTest UI 테스트는 아니다.
- 임시 로컬 파일 시스템 fixture이므로 외장 APFS, 대소문자 구분 APFS, exFAT, SMB 동작을 입증하지 않는다.
- 휴지통은 시스템 Trash를 변경하므로 이 자동 fixture에서 실행하지 않았다. 해당 실제 UI 수동 검증은 별도 남는다.
