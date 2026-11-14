# M7 Increment 113 — Git 동기화의 원격 브랜치 선택

동기화는 Git이 보고한 upstream의 원격 이름과 브랜치 ref를 사용한다. 가져온 추적 ref로 fast-forward한 다음 같은 원격 브랜치에 단일 refspec으로 푸시한다. 일반 푸시도 유효한 로컬 브랜치에서 같은 이름의 원격 브랜치만 갱신한다. 미러 설정, 강제 푸시 refspec과 자동 태그 전송이 이 작업에 적용되지 않도록 했다. [Git의 upstream ref 필드](https://git-scm.com/docs/git-for-each-ref) · [Git 푸시 및 미러 동작](https://git-scm.com/docs/git-push)

임시 bare 원격에서 로컬 topic/local이 origin/main을 추적하도록 설정했다. 미러, 와일드카드 강제 refspec, 자동 태그 전송, pull rebase 설정이 있는 상태에서도 동기화 후 원격에는 main만 남았다. refspec 형태의 브랜치 입력과 원격보다 뒤처진 브랜치의 푸시가 거부됐고, 원격의 최신 커밋이 유지됐다. Swift 테스트 217개가 통과했다. 외부 서비스 검증은 출시 현황에서 계속 추적한다.
