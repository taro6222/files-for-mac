# M3 열여섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 외형 설정 패널에서 저장된 폴더별 보기 개수 표시
- 저장값이 있을 때만 활성화되는 전체 초기화 동작
- 초기화 후 저장 데이터 제거와 열린 창의 전역 기본값 복귀
- 폴더별 설정이 없는 경우 안전한 no-op

## 자동 및 실제 UI 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 88개 테스트 통과. 단위 테스트에서 전체 초기화 후 메모리 상태와 `UserDefaults` 데이터 제거를 검증했다.

`DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh` 결과 한국어/영어 × 밝게/어둡게 네 조합에서 `folderSettingsManagement`, `folderSettingsResetAll`을 포함한 모든 검사가 `true`였다. 각 조합의 `appearance-settings.png`를 다시 생성하고 한국어 다크 화면에서 저장 개수와 전체 초기화 버튼의 배치·잘림 여부를 직접 확인했다.

## M3 수용 상태

상세·그리드·목록·컬럼·적응형 보기, 보기 크기, 명령 팔레트, 사용자 단축키, 툴바, 외형, 폴더별 보기 및 설정 관리 구현은 검증되었다. 그러나 원본 Windows 실행 캡처와의 사람 검토, VoiceOver, 실제 대비 증가·투명도 감소, Intel·SMB 등 환경 검증이 남아 있어 M3 전체 완료로 표시하지 않는다. 독립적인 M4 구현은 계획대로 진행한다.
