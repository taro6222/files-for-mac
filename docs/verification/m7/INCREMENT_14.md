# M7 Increment 14 — 복사 충돌 처리의 키보드와 접근성

복사 충돌 정책 창에서 ⌘S로 충돌 항목을 건너뛰고 Esc로 취소할 수 있다. 복사 창에서도 Esc로 취소를 요청할 수 있으며, 결과가 나오면 Return으로 닫을 수 있다. 진행률 막대와 상세 결과에 한국어·영어 접근성 이름을 지정했다. 취소 요청과 최종 요약을 macOS 접근성 알림으로 전달한다. [Apple 접근성 알림 API](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/announcementrequested)

Apple Silicon macOS 27.2 (26B123)에서 실제 AppKit 창에 테스트 키 이벤트를 전달했다. ⌘S로 충돌 정책을 적용하고, 기존 대상 파일의 내용이 유지되고 추가 복사본이 생기지 않는지 확인했다. 결과 창에서 충돌 1건과 접근성 이름을 확인했고 Return으로 창이 닫혔다. 한국어·영어 및 밝게·어둡게 조합별 AppKit 파일 작업 검사 35개를 통과했다.

이 검증은 충돌 정책 창부터 결과까지를 다룬다. 파일 탐색과 시스템 폴더 선택을 포함한 전체 키보드 동선 및 VoiceOver 음성·점자 출력은 추가 검증이 필요하다.
