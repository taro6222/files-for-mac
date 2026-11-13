# M4 열다섯 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 임시 실제 APFS, 대소문자 구분 APFS, exFAT 볼륨 생성·장착·정리
- `MountedVolumeProvider`가 Finder에 보이는 세 볼륨을 모두 탐지하는지 확인
- 각 볼륨의 총/가용 용량, 포맷 설명, 로컬 상태 확인
- 기존 복사·검증·이동·교체 백업·Undo·대소문자 의미 매트릭스 재실행
- 숨겨진 `-nobrowse` 볼륨은 `.skipHiddenVolumes` 정책상 UI에서 제외됨을 검증 스크립트에 반영

## 검증

- `scripts/verify-volume-matrix.sh`: 실제 볼륨 관련 3개 테스트 통과
- 전체 Swift 테스트 및 FilesMac 빌드: 95개 테스트 통과
- APFS/APFSX/exFAT 모두 provider 탐지 및 파일 작업 매트릭스 통과
- 스크립트 종료 시 장치 detach와 프로젝트 전용 임시 디렉터리 정리

## 남은 항목

- 실제 물리 외장 드라이브의 사용자 확인형 추출과 장착 해제 알림
- 실제 인덱싱 완료 콘텐츠의 Spotlight hit
- Quick Look 확장 본문 렌더링
- 검색 크기 단위 선택

따라서 M4 완료로 표시하지 않는다.
