# M7 Increment 131 — exFAT 생성 시간 보존

APFS와 exFAT 사이에서 복사·교차 볼륨 이동·이동 실행 취소 시 파일과 폴더의 생성 시간을 임시 복사본에 복원하고 게시 전에 비교한다. 테스트 호스트인 macOS 27.2에서 파일과 폴더에 생성 시간을 직접 쓰고 읽는 대조를 수행했다. exFAT 규격의 필드는 10 ms 단위를 제공하지만 macOS가 노출한 값은 정수 초였다. 짝수 초 + 123 ms와 홀수 초 + 999 ms에서 모두 소수 초만 사라졌다. 이 결과에 맞춰 exFAT가 포함된 전송에서는 1초 미만의 차이를 허용한다. [exFAT 생성 시간 필드 규격](https://learn.microsoft.com/en-us/windows/win32/fileio/exfat-specification#745-createtimestamp-create10msincrement-and-createutcoffset-fields)

소수 초가 포함된 서로 다른 생성 시간을 상위 폴더, 하위 폴더, 파일에 지정해 실제 대소문자 구분 APFS와 exFAT에서 복사·이동·이동 실행 취소를 검사했다. exFAT에서 APFS로 돌아올 때는 exFAT에 기록된 시간이 보존됐다. Swift 테스트 229개와 실제 마운트 검사 6개가 통과했다. FAT·HFS 및 SMB의 생성 시간과 접근 시간은 별도 검증 대상이다.
