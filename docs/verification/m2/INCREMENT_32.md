# M2 서른두 번째 개발 단위 검증

검증일: 2026-11-13

## 범위

- 사용자가 마운트한 실제 SMB 공유를 대상으로 하는 반복 가능한 수용 검증 진입점
- 로컬 경로를 SMB로 오인하지 않도록 셸과 Swift 양쪽에서 `smbfs` 확인
- 격리된 고유 fixture의 폴더 복사·내용 검증·Undo
- 교차 볼륨 이동·Undo와 기존 대상 교체·백업 복원

## 실행 방법

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
scripts/verify-smb-volume.sh /Volumes/<mounted-smb-share>
```

스크립트는 실제 `smbfs`이면서 쓰기 가능한 경로만 허용한다. 공유 루트 아래 고유한 `FilesM2-SMB-<UUID>` 폴더만 사용하고 종료 시 fixture를 정리한다.

M7부터 전체 명령에 기본 180초 제한을 적용한다. 필요한 경우 `FILES_SMB_TIMEOUT_SECONDS`에 양의 정수 초를 지정할 수 있다. 시간 초과 시 종료 코드 124를 반환한다. 강제 종료로 fixture 정리가 중단될 수 있으므로 공유가 다시 응답하면 이번 실행이 만든 고유 폴더를 확인한다. [M7 SMB 마운트 검증](../m7/INCREMENT_36.md)

## 이번 환경의 결과

- `mount`와 `smbutil statshares -a`에서 연결된 SMB 공유가 없음을 확인했다.
- 비 SMB 경로에서 검증을 통과시켰다고 기록하지 않는다.
- 전체 Swift 회귀 테스트에서는 환경 변수가 없을 때 외부 상태 변경 없이 건너뛰도록 구성했다.

## 남은 수용 검증

- 실제 SMB 공유에서 집중 테스트 통과
- 정상·지연·단절·인증 만료·서버 공간 부족 조건
- SMB의 FSEvents/갱신 지연과 외부 변경 반영
- 위 결과가 없으므로 M2 전체 완료로 표시하지 않는다.
