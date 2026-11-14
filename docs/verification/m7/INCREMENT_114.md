# M7 Increment 114 — 앱의 Git 명령에서 로컬 훅 비활성화

Files for Mac에서 실행하는 Git 명령에 프로세스 단위로 core.hooksPath와 core.fsmonitor를 지정한다. 저장소와 시스템 Git 설정 파일을 그대로 유지한다. 이 동작은 Git 상태 패널에 표시하는 로컬 훅 지원 범위와 일치한다. [Git 설정 레퍼런스](https://git-scm.com/docs/git-config)

임시 저장소에서 실행 시 표시 파일을 만들고 실패하는 pre-push 및 fsmonitor 훅을 설정했다. 앱의 upstream 동기화가 정상 완료되고 두 표시 파일이 생성되지 않았음을 확인했다. 사전에 설정한 저장소 hooksPath와 원격의 브랜치·태그 범위도 대조했다. Swift 테스트 217개와 앱 빌드가 통과했다.
