# M7 Increment 185 — macOS CI의 루프백 SMB 실마운트

수동 `macOS SMB integration` 작업은 macOS 15 Apple Silicon 러너에서 검증 실행 파일을 빌드하고 Samba를 임시로 실행한다. 루프백 주소의 높은 포트만 사용하고 시험 공유·서버 상태·마운트를 임시 폴더에 만든다. macOS SMB 클라이언트가 실제 공유를 마운트하면 협상 정보를 기록하고, 디렉터리 열거와 파일 생성·읽기·이름 변경·삭제를 확인한 뒤 복사·이동·실행 취소 Swift 회귀를 실행한다.

`verify-smb-volume.sh --skip-build` 경로는 CI가 미리 빌드한 시험을 실행한다. 로컬에서 비 SMB 경로 거부와 잘못된 인자 거부를 확인했다. 모의 명령으로 루프백 바인딩, 정상 실행 호출, 마운트 이후 실패를 반환할 때의 마운트 해제와 서버 종료를 검증했다. 실제 SMB 결과와 외부 서버 환경은 출시 검증표에서 추적한다.

[Homebrew의 Samba 패키지](https://formulae.brew.sh/formula/samba)와 [Samba 설정 문서](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)를 사용했다.
