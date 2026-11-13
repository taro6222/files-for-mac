# M5 쉰한 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- Git 상태 패널에 지원 명령과 제외 범위를 한국어·영어로 상시 표시
- 자격 증명을 앱/URL에 저장하지 않고 시스템 Git 설정·credential helper·SSH agent에 위임함을 명시
- stage·commit, submodule, Git LFS, hook 실행을 지원하지 않음을 명시
- 지원 범위 안내에 접근성 label 추가
- 플랫폼 차이 결정 기록과 F27 대응표 동기화

## 검증

- 전체 Swift Testing 153개 통과 및 FilesMac debug build 통과
- 한국어/영어 × 밝게/어둡게 UI 4조합 전체 통과
- 네 조합 모두 Git 지원 범위 안내 표시와 접근성 label 확인
- 기존 Git 상태·clone·상태 열·다중 창 선택·Quick Look 검증 회귀 없음

## 남은 항목

- 인증 HTTPS/SSH remote 실환경 수용
- 상세 보기 외 Git 상태 표식과 큰 저장소 최적화
- M5 압축·클라우드·원격·Git 전체 종료 감사

따라서 M5 전체 완료로 표시하지 않는다.
