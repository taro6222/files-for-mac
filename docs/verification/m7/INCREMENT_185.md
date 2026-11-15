# M7 Increment 185 — macOS CI의 루프백 SMB 실마운트

수동 `macOS SMB integration` 작업은 macOS 15 Apple Silicon 러너에서 검증 실행 파일을 빌드하고 Samba를 임시로 실행한다. 루프백 주소의 높은 포트만 사용하고 시험 공유·서버 상태·마운트를 임시 폴더에 만든다. macOS SMB 클라이언트가 실제 공유를 마운트하면 협상 정보를 기록하고, 디렉터리 열거와 파일 생성·읽기·이름 변경·삭제를 확인한 뒤 복사·이동·실행 취소 Swift 회귀를 실행한다.

`verify-smb-volume.sh --skip-build` 경로는 CI가 미리 빌드한 시험을 실행한다. 로컬에서 비 SMB 경로 거부와 잘못된 인자 거부를 확인했다. 모의 명령으로 루프백 바인딩, 정상 실행 호출, 마운트 이후 실패를 반환할 때의 마운트 해제와 서버 종료를 검증했다. 실제 SMB 결과와 외부 서버 환경은 출시 검증표에서 추적한다.

[Homebrew의 Samba 패키지](https://formulae.brew.sh/formula/samba)와 [Samba 설정 문서](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)를 사용했다.

[첫 실제 러너 시험](https://github.com/taro6222/files-for-mac/actions/runs/43653493820)에서 macOS 15.8.2의 Swift 시험 빌드와 Samba 4.25.1 설치가 통과했다. Samba가 루프백 연결을 받기 전에 코드 1로 종료해 SMB 마운트와 파일 작업을 실행하지 못했다. 서버가 만든 `cores` 디렉터리의 권한으로 임시 폴더 정리도 실패했다.

임시 경로를 짧게 만들고 RPC 소켓을 시험 상태 폴더에 둔다. [Samba 포그라운드 실행의 표준 입력 처리](https://github.com/samba-team/samba/blob/samba-4.25.1/source3/smbd/server.c#L2808-L2826)에 따라 CI의 입력 파이프 대신 `/dev/null`을 넘긴다. 서버 로그 수준을 높이고 서버 종료 시 생성된 임시 폴더 전체를 정리한다. 모의 조기 종료에서 원래 실패 전달과 임시 경로 정리 호출을 확인했다.

[두 번째 러너 시험](https://github.com/taro6222/files-for-mac/actions/runs/43654417167)에서 Samba 4.25.1이 macOS 15.8.2 클라이언트의 마운트를 받았다. SMB 3.1.1을 협상하고 디렉터리를 조회했다. 게스트의 첫 시험 폴더 생성은 접근 거부였고 복사·이동 Swift 시험까지 도달하지 못했다. 정리 중 단계의 종료 코드는 143이었다.

다음 시험은 러너 계정에 임시 Samba 자격 증명을 만들고 공유를 이 계정으로 마운트한다. 시험 전용 passdb를 사용하며 마운트 오류 로그에는 임시 비밀번호를 표시하지 않는다. 서버를 별도 프로세스 세션에서 시작한다. 모의 명령에서 자격 증명 준비 순서, 마운트 오류가 자격 증명을 노출하지 않는 응답, 서버 종료와 Swift 검증 호출 조건을 확인했다. [Samba 인증 도구](https://www.samba.org/samba/docs/current/man-html/smbpasswd.8.html)
