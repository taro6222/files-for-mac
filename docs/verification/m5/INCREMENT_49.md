# M5 마흔아홉 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- HTTPS·SSH·file URL 및 로컬 절대 경로 입력 UI
- 새 clone 대상 경로 선택과 기존 대상 사전 거부
- sibling staging clone 완료 후에만 최종 폴더 publish
- 진행 중 입력 잠금·중단·앱 종료 경고 연결
- 성공 후 새 BrowserWindow로 clone 위치 탐색
- 오류·취소 시 최종 대상 미생성과 staging 정리 안내

## 검증

- 전체 Swift Testing 153개 통과 및 FilesMac debug build 통과
- 한국어/영어 × 밝게/어둡게 UI 4조합에서 현재 저장소 file URL 실제 clone 통과
- 네 조합 모두 clone 완료 callback 경로와 `.git` 디렉터리 확인
- Git clone 메뉴 catalog·입력/상태 접근성 및 화면 캡처 통과
- QA URL trailing slash 차이는 표준 경로 비교로 교정

## 남은 항목

- 로컬 파일 목록 Git 상태 열·지연 갱신
- 인증 HTTPS/SSH remote 실환경 검증
- submodule·LFS·hook 지원 경계 문서화

따라서 M5 Git 영역 완료로 표시하지 않는다.
