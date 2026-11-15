# M7 Increment 200 — macOS 확장을 사용하는 SMB 시험 공유

[인증 재시험](https://github.com/taro6222/files-for-mac/actions/runs/43657904685)에서 공유 폴더 생성과 파일 쓰기·읽기·이름 변경·삭제가 통과했다. 앱의 Swift 통합 시험이 실행됐고 임시 복사본의 데이터를 읽었다. 이어 POSIX 권한 보존 검증에서 복사가 실패해 실행 취소와 교차 볼륨 이동 검증에는 도달하지 못했다.

일회용 Samba의 시험 공유에 `fruit`와 `streams_xattr`를 함께 적용하고 AAPL과 NFS ACE를 활성화한다. Samba 문서에서 이 조합은 macOS 클라이언트가 UNIX 모드를 읽고 변경할 수 있도록 한다. 앱은 종전과 같은 파일 내용·메타데이터 검증을 적용한다. [Samba vfs_fruit 설명서](https://www.samba.org/samba/docs/current/man-html/vfs_fruit.8.html)

Python 구문을 검사했다. 새 설정의 실제 마운트와 복사·이동 검증은 GitHub Actions에서 재실행한다.
