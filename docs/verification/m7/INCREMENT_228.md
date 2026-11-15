# M7 Increment 228 — SMB 게시 전후 파일 식별자 대조

[SMB 실마운트 재시험](https://github.com/taro6222/files-for-mac/actions/runs/43666939948)에서 복사와 독립 목록 조회가 통과했다. 복사 실행 취소는 복사본을 변경된 항목으로 판정했으나 장부와 게시본의 내용·모드·확장 속성·ACL·생성 및 수정 시각이 모두 일치했다. 이동은 게시 후 대상 검증에서 중단됐고 원본의 바이트가 보존됐다.

Samba의 `fruit` 모듈은 AAPL 연결에서 서버 파일 식별자 대신 0을 보고할 수 있다. 이번 실패는 macOS가 노출하는 파일 식별자가 게시 전후 달라졌을 가능성을 보여 준다. 시험 공유에 임시 파일을 만들고 이름을 바꾸면서 경로의 식별자와 열린 파일 디스크립터의 식별자를 각각 읽는다. 복사 실행 취소가 실패하면 장부와 게시본의 식별자도 출력한다. [Samba `vfs_fruit` 매뉴얼](https://www.samba.org/samba/docs/current/man-html/vfs_fruit.8.html)

Apple Silicon에서 변경한 Swift Testing 파일의 타입 검사를 통과했다. 서버 설정과 앱의 검증 조건은 유지하고 실제 SMB 결과로 원인을 확인한다.
