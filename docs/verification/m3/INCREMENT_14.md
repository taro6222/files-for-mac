# M3 열네 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 시스템 설정 사용, 밝게, 어둡게의 세 가지 앱 외형
- 설정 변경 즉시 전체 앱과 열린 탐색 창에 반영
- 선택값 저장, 재실행 복원, 알 수 없는 저장값의 시스템 기본값 복구
- `NSVisualEffectView` sidebar 재질을 유지해 macOS의 대비 증가·투명도 감소 설정 추종
- 앱 메뉴에서 접근하는 네이티브 외형 설정 패널

## 자동 및 실제 UI 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 87개 테스트 통과. 단위 테스트에서 잘못된 값 복구, 저장·재로딩, 변경 알림, 같은 값 재설정의 불필요한 알림 방지를 검증했다.

`DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 `appearanceDark`, `appearanceLight`, `appearanceSystem`, `appearanceSettingsWindow`를 포함한 모든 검사가 `true`였다. 각 조합의 `appearance-settings.png`를 생성하고 한국어 다크 화면의 테마 선택과 macOS 접근성 재질 안내를 직접 확인했다.

## 남은 항목

- 폴더별 보기 설정과 전역 설정의 우선순위·초기화
- 사용자 강조색·글꼴 크기 범위의 원본 기능 대조
- VoiceOver와 실제 시스템 대비 증가·투명도 감소를 켠 수동 확인
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
