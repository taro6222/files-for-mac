# M5 스물여섯 번째 개발 단위 검증

검증일: 2026-11-14

## 범위

- ssh-keyscan 형식 host key 후보의 host token·port·key type·base64 검증
- SHA-256 key fingerprint를 OpenSSH 형식 `SHA256:<base64-no-padding>`으로 계산
- 사용자가 확인해 전달한 fingerprint가 정확히 일치할 때만 승인
- known_hosts를 mode 0600 staging 파일에 기록·fsync 후 원자 교체
- 같은 host/key type/키의 중복 승인은 한 줄로 유지
- 같은 host/key type의 다른 키는 `hostKeyChanged`로 차단하고 기존 신뢰 보존
- 자동 수집 결과를 곧바로 신뢰하지 않음

## 검증

- non-default port host token과 fingerprint 결정성 확인
- 다른 host·미지원 DSA·잘못된 base64·제어문자 거부 확인
- fingerprint 불일치 시 파일 미생성 확인
- 최초 승인·동일 후보 재승인 후 한 줄과 mode 0600 확인
- 변경된 키 승인 차단 및 기존 known_hosts 내용 보존 확인
- 전체 Swift Testing 136개 및 UI 한국어/영어 × 라이트/다크 4조합 통과

## 남은 항목

- ssh-keyscan subprocess의 출력·시간 제한과 후보 선택
- fingerprint·key type을 보여주고 사용자가 직접 승인하는 AppKit UI
- host key 변경 시 기존/새 fingerprint를 함께 표시하는 복구 흐름

따라서 M5 원격 연결 영역 완료로 표시하지 않는다.
