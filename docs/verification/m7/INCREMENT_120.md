# M7 Increment 120 — 전송 중 확장 속성 검증

복사, 폴더 병합의 새 항목 복사, 교차 볼륨 이동과 그 역방향 복사는 게시 전에 앱이 읽을 수 있는 확장 속성의 이름과 SHA-256을 비교한다. Finder 태그도 같은 비교를 거친다. 목록을 읽을 때 심볼릭 링크를 따라가지 않으며, 일반 확장 속성은 한 번에 한 개씩 읽는다. 리소스 포크는 기존의 분할 읽기를 사용한다. [속성 목록 API](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/listxattr.2.html) · [속성 읽기 API](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getxattr.2.html)

교차 볼륨에서 원본을 삭제하기 직전에 원본과 게시한 파일을 다시 확인한다. 게시한 파일의 확장 속성이 바뀌면 두 파일을 보존한다. 원본만 바뀌었을 때는 확인한 게시본을 정리하고 원본을 보존한다. 교체 이동 실행 취소에서 중단 후 다시 시작할 때도, 복원본과 삭제 후보의 속성이 일치해야 삭제한다.

같은 길이의 확장 속성 값을 임시 복사본, 게시된 대상, 원본에서 각각 바꾼 세 회귀를 포함해 Swift 테스트 222개가 통과했다. APFS·대소문자 구분 APFS·exFAT 실제 마운트 검사 4개도 통과했다. ACL과 시간의 전송 전후 비교, 속성 손실 원인을 구체적으로 안내하는 메시지, 기존 실행 취소 기록에 일반 확장 속성 해시를 보관하는 작업은 남아 있다.
