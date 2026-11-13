# M3 여덟 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 최대 200개 파일 표본을 사용하는 결정적 적응형 보기 정책
- 이미지·영상 비율이 60% 이상이고 파일이 3개 이상이면 그리드 선택
- 미디어 중심이 아닌 560pt 미만 pane은 목록, 그 외는 상세 보기 선택
- 로딩 완료 전 레이아웃 전환 금지와 완료 후 한 번의 재분류
- 창 및 분할 pane 폭 변경 시 적응형 모드만 재평가
- 사용자가 상세·목록·그리드·컬럼을 명시적으로 선택하면 적응형 정책이 덮어쓰지 않음
- 적응형 상태 자체는 탭 및 workspace session에 보존

## 자동 검증

전체 Swift 테스트 및 FilesMac 빌드 결과: 83개 테스트 통과.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-ui.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/verify-m2-ui.sh
```

결과: 한국어/영어 × 밝게/어둡게 네 조합에서 다음 항목을 포함한 모든 검사가 `true`였다.

- `adaptiveMediaUsesGrid`
- `adaptiveManualChoiceWins`
- `secondaryAdaptiveCompactList`
- 기존 상세·목록·그리드·컬럼 및 파일 작업 회귀 검사

정책 단위 테스트는 미디어 비율, 폴더 제외, 좁은 폭, 넓은 폭, 표본 개수 상한을 검증했다.

## 남은 항목

- 목록/그리드 크기·간격 사용자 지정과 저장
- 컬럼 보기의 컨텍스트 메뉴와 Finder/다른 pane 드래그 앤 드롭
- 폴더별 보기 설정과 전체 폴더 동기화의 원본 동작 대조
- 원본 Windows 화면과 시각 기준 대조

따라서 M3 완료로 표시하지 않는다.
