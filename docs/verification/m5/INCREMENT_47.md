# M5 마흔일곱 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- Git subprocess를 task cancellation handler에 연결
- 취소가 실행 전이면 launch하지 않고, 실행 중이면 해당 Process에 terminate 전달
- stdout·stderr를 동시에 drain해 pipe 포화 교착 방지
- 취소된 clone의 sibling staging 디렉터리 정리
- 취소 시 최종 clone 대상 경로를 publish하지 않음

## 검증

- 5초 대기 fake Git process를 100ms 뒤 취소해 `CancellationError` 확인
- subprocess 종료 뒤 최종 대상 미생성과 `.files-git-clone-*` 잔여 없음 확인
- 전체 Swift Testing 153개 통과
- FilesMac debug build 통과

## 남은 항목

- Git AppKit 패널과 상태 열 연결
- 인증이 필요한 HTTPS/SSH remote 실환경 검증
- submodule·LFS·hook 지원 경계 문서화

따라서 M5 Git 영역 완료로 표시하지 않는다.
