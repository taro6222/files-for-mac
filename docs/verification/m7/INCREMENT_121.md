# M7 Increment 121 — 파일 권한과 ACL 검증

복사, 폴더 병합과 교차 볼륨 이동 및 실행 취소에서 확장 ACL을 확인한다. 권한 변경을 검사할 때 심볼릭 링크를 따라가지 않는다. POSIX 권한을 제공하는 볼륨 간에는 임시 복사본의 모드도 원본과 비교한다. exFAT와 FAT에서는 운영체제가 합성한 모드가 표시되므로 볼륨이 다른 두 파일의 모드를 직접 비교하지 않는다. 이동 중 원본이나 게시된 파일의 권한이 바뀌는지는 각각의 이전 상태와 비교한다. [macOS ACL 읽기 API](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/acl_get_file.3.html)

교차 볼륨 이동의 임시 복사본에 ACL을 삽입하거나 POSIX 모드를 변경했을 때 최종 경로에 게시하지 않고 원본을 보존했다. 실제 exFAT 볼륨이 ACL을 보존하지 못한 경우에도 원본과 ACL을 보존했다. Swift 테스트 224개와 실제 APFS·대소문자 구분 APFS·exFAT 마운트 검사 5개가 통과했다.

시간 비교, 파일 시스템별 권한 차이에 대한 사용자 안내, 실행 취소 저널의 확장 메타데이터 검증은 남아 있다.
