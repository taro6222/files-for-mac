# M7 Increment 194 — 인증 SMB 시험 공유의 폴더 생성

[인증 SMB 실행](https://github.com/taro6222/files-for-mac/actions/runs/43656067672)에서 macOS 15.8.2가 로컬 Samba 4.25.1의 공유를 SMB 3.1.1로 마운트했고 목록 조회도 통과했다. 파일 작업 사전 검사 중 Samba가 임시 폴더를 최종 이름으로 바꾸다가 `NT_STATUS_ACCESS_DENIED`를 반환했다. 앱의 파일 작업 시험은 이 실행에서 시작되지 않았다.

Samba 개발자 목록에서 안내한 `vfs mkdir use tmp name = no`를 일회용 CI 공유에 적용했다. 사전 검사는 마운트에서 폴더 생성, 파일 쓰기·읽기·이름 변경·삭제를 계속 실행한다. 앱과 실제 사용자 서버의 설정에는 손대지 않았다. [Samba 개발자 목록](https://lists.samba.org/archive/samba-technical/2025-October/140074.html)

Python 구문을 검사했다. 변경한 설정의 실제 마운트 검증은 GitHub Actions에서 진행한다.
