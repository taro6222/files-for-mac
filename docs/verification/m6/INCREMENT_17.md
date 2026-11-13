# M6 Increment 17 — macOS 코드 서명 정보

검증일: 2026-11-14

## 구현

- 정보 창에서 선택 항목의 macOS 코드 서명을 명시적으로 검사할 수 있다.
- `/usr/bin/codesign`에 경로를 별도 인자로 전달하고 출력은 256 KiB로 제한한다.
- 유효·서명 없음·유효하지 않음을 구분하고 Identifier, TeamIdentifier, Authority, Format을 표시한다.
- Windows Authenticode와 같다고 주장하지 않고 네이티브 code-signing 대체로 기록한다.

## 검증

- 메타데이터 parser 단위 테스트를 추가했다.
- `swift test`: 156개 통과.
- UI QA는 일반 파일의 서명 검사 완료와 정보 창 표시를 4개 언어·테마 조합에서 확인한다.
- 화면 감사: macOS 대체 24, 플랫폼 제외 4, 검토 대기 5.

## 남은 항목

- 실제 Developer ID 서명 앱과 손상된 서명 fixture는 M7 서명·공증 게이트에서 검증한다.
