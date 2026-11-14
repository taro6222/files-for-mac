# M7 Increment 36 — SMB 마운트와 검증 제한 시간

Apple Silicon macOS 27.2 (26B123)에서 격리한 루프백 공유를 macOS `smbfs`로 마운트했다. Impacket 0.13.0 공유에서는 기본 디렉터리 조회가 5초 내 반환되지 않았다. DittoFS 0.36.0 공유에서는 SMB 3.1.1 협상과 서명된 요청을 서버 로그에서 확인했지만, 기본 파일 시스템 명령과 통합 시험이 지정 시간 안에 끝나지 않았다. [DittoFS 릴리스](https://github.com/cubbit/dittofs/releases/tag/v0.36.0)

`scripts/verify-smb-volume.sh`는 이제 사전 검사와 Swift 시험을 별도 프로세스 그룹에서 실행한다. 기본 180초를 초과하면 그룹을 종료하고 코드 124를 반환한다. `FILES_SMB_TIMEOUT_SECONDS`로 제한 시간을 조절할 수 있다.

실제 루프백 `smbfs`에서 8초 제한을 적용해 종료 코드 124를 확인했다. 셸 구문, APFS 경로 거부(65), 없는 디렉터리 거부(66), 잘못된 제한 시간 거부도 확인했다. 일반 Swift 회귀 203개를 통과했다. 정상 응답하는 공유에서 복사·이동·실행 취소와 교체 취소를 완료하고, 연결 중단·재연결·권한·외부 변경 반영을 검증해야 한다.
