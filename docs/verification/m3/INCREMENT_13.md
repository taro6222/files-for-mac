# M3 열세 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 뒤로·앞으로·상위 폴더·새로고침·경로·숨김 항목·보기 모드·즐겨찾기·보기 옵션의 순서 저장
- 항목별 표시·숨김과 모든 창 즉시 반영
- 경로 필드를 필수 항목으로 유지하고 손상되거나 중복된 저장값 복구
- 900×600 최소 창에서 부가 항목을 네이티브 overflow 메뉴로 이동
- 툴바 사용자 지정 패널의 순서 변경, 표시 전환, 기본값 복원

## 자동 및 실제 UI 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 86개 테스트 통과. 단위 테스트에서 잘못된 순서 복구, 필수 경로 필드 보호, 표시 설정 저장, 순서 이동과 전체 초기화를 검증했다.

`DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 `toolbarSettingsWindow`, `toolbarCompactOverflow`, `toolbarVisibilityPreference`, `toolbarOrderPreference`를 포함한 모든 검사가 `true`였다. 각 조합의 `toolbar-settings.png`를 생성하고 한국어 다크 화면에서 아홉 개 항목, 표시 상태, 재정렬·숨김·복원 컨트롤을 직접 확인했다.

## 남은 항목

- light/dark/system 테마, 강조색·배경 재질과 투명도 감소 대응
- 폴더별 보기 설정과 전역 설정의 우선순위·초기화
- VoiceOver로 사용자 지정 패널 직접 확인
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
