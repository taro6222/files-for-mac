# M6 Increment 55 — 휴지통 전용 그룹화 경계

검증일: 2026-11-14

## 원본 확인

고정 원본 SHA `99951c66928c4da714da8b1dd46039421182cbab`의 `GroupAction.cs`에서 다음 명령은 `ContentPageTypes.RecycleBin`에서만 실행 가능하다.

- `GroupByOriginalFolder`
- `GroupByDateDeleted`
- `GroupByDateDeletedYear`
- `GroupByDateDeletedMonth`
- `GroupByDateDeletedDay`

## macOS 판정

- macOS 공개 API에는 시스템 전체 휴지통 항목을 원래 경로와 신뢰할 수 있는 삭제 날짜까지 포함해 열거하는 Files 동등 인터페이스가 없다.
- 앱의 작업 저널은 앱이 직접 휴지통으로 이동한 항목의 안전한 복원에만 사용하며 Finder나 다른 앱이 버린 항목을 포함하지 않는다.
- 불완전한 앱 저널을 시스템 휴지통 전체 화면처럼 표시하거나 동작 없는 그룹 메뉴를 노출하지 않고 5개 명령을 `platform-excluded`로 유지한다.

## 검증

- 패리티 감사에서 202개 명령 행과 상태 어휘가 유효한지 확인한다.
- 일반 폴더·검색·클라우드 그룹 명령은 이 판정에 포함하지 않고 후속 구현 대상으로 유지한다.
