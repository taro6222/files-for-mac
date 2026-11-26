# 372 — 압축 편집본 검증 연결, F23 진행 중

이번 변경은 별도 편집본의 검증까지 연결한 중간 구현이다. **원본 교체·백업·복구·Undo·편집 화면은 아직 연결하지 않았다.** update capability는 계속 false다.

## 실제 변경

SDK에 디스크 출력을 만들지 않는 audit를 추가했다. 격리 helper 안에서 모든 항목을 디코딩하며 CRC/암호 결과와 예상 크기를 확인하고 SHA-256 sink로만 내용을 받는다. 경로나 링크 대상을 호스트에 만들거나 따라가지 않는다. 일반 파일뿐 아니라 기존 불투명 링크의 stream도 검증한다. 정상 결과만 원본 snapshot에 묶어 cache하고 한 번에 최대 256항목을 응답한다. 다음 페이지에서도 source 변경과 더 작은 요청 상한을 다시 검사한다. 10만 항목·압축 파일 8GB·단일 파일 8GB·총 내용 20GB, 속성당 1MiB·속성 전체 256MiB 상한을 적용한다. 기존 부모의 자원 관찰·취소/기한·PID 회수도 유지한다.

읽기 전용 inspect 모드를 추가해 출력 pipe 이외의 파일 쓰기 FD 없이 audit/list/close만 허용한다. 편집 시작 요청은 거부한다. 원본과 편집본은 서로 다른 helper 세션에서 읽으며 codec은 같은 고정 SDK다. 이를 다른 codec 구현에 의한 보편적 검증이라고 주장하지 않는다. 실제 시험 결과는 별도로 공식 7-Zip 복원과 비교했다.

Swift 내부 `writeVerifiedEditCandidate`는 다음을 확인하고 원본/편집본의 파일 증명을 반환한다.

- 전체 결과의 항목 수·정확한 경로·종류·크기와 암호화 상태. 7z writer의 항목 재정렬은 경로로 대응한다.
- 유지 항목의 내용 SHA-256과 생성/접근/수정 시각, 속성·Unix 권한, 설명·링크 대상 속성의 digest. 경로와 압축 방식/배치 정보는 별도로 다룬다.
- 새 파일의 실제 읽기 전용 입력 내용 SHA-256과 snapshot, 새 파일/폴더의 권한·수정 시각 및 빈 폴더 내용. 새 폴더는 현재 생성 시각을 기록한다.
- archive 설명과 header 암호 요청 상태. 빈 암호 archive 등의 정책은 아직 전체 수용하지 않았으며 차이는 성공으로 넘기지 않는다.
- 원본과 편집본의 inode·device·크기·mode·소유자·link 수·mtime/ctime 및 전체 주 데이터 fork 해시를 검증 전후 비교한다. 이것은 archive 파일의 모든 외부 xattr/ACL/resource fork 보존 완료를 뜻하지 않는다.

반환 결과는 원본 교체 허가가 아니다. 다음 저장 transaction에서 경로·부모·원본/출력·백업과 metadata를 재검증하고 저널을 남겨야 한다. 오류 출력은 caller 소유의 partial candidate일 수 있다. 기존 미검증 candidate API도 제품 게시에 사용하지 않는다.

## 검증 중 발견한 차이

libarchive가 만든 ZIP의 미지정 생성/접근 시각은 처음에는 VT_EMPTY였다. SDK가 NTFS extra를 쓰면서 해당 slot에 zero FILETIME을 넣고 다시 읽을 때 VT_FILETIME으로 반환했다. 로컬 진단의 원본/출력 속성 덤프에서 수정 시각·권한은 같고 그 두 필드만 달라짐을 확인했다. SDK writer도 FILETIME_IsZero를 미지정 시각의 조건으로 사용한다. 이 생성/접근 시각의 zero sentinel만 논리적으로 미지정 값으로 정규화한다. 실제 nonzero 시각과 수정 시각의 정밀도·다른 속성·내용 해시를 무시하지 않는다.

초기 거부 로그와 진단 자료는 `build/edit-372-property-probe/` 및 `build/edit-372-verified-candidate*.log`에 보존한다. 통과 결과로 초기 실패를 덮지 않았다.

## 최종 검증

| 범위 | 결과 |
|---|---|
| Debug / Release | 8.15초 / 34.00초 빌드 통과 |
| Swift 클라이언트·번들 | 62개 통과 |
| 실제 App Sandbox helper | 113개 통과 |
| 비격리 SDK/helper 진단 | 205개 통과 |
| native 편집 probe / OS 권한 probe | 83개 / 15개 통과 |

비암호 ZIP/7z·암호 ZIP·Unicode/헤더 암호 7z의 편집본을 전부 audit한 뒤 공식 7-Zip으로 복원했다. 외부에서 원본이나 편집본을 다른 유효 archive로 바꿔도 성공을 반환하지 않고 변경된 파일을 보존한다. 301항목의 실제 페이지/cache·중간 source 변경·작은 후속 상한·CRC 손상·불투명 링크 내용·inspect의 쓰기 거부도 검사했다.

기존 Unicode AES ZIP의 metadata 편집은 별도 source/output audit와 원본 보존을 통과했다. 잘못된 암호와 미지원인 새 암호 payload 추가는 출력 전에 거부됐다. **후자의 기능은 여전히 미완료**이며 ASCII 암호만 허용하는 제품으로 범위를 줄이지 않는다.

로컬 GUI·전체 AppKit·장시간 시험 앱은 실행하지 않았다. [소스와 최종 보고서 해시](edit-verification-372.json)를 보존한다. 이전 371 원격 실행 45860713694는 관찰 당시 Intel 실행 중/ARM 대기 상태였으며 최신 양 CPU 수용으로 집계하지 않는다. M7 정식 출시는 미완료이고 인증서/공증 프로필은 사용자 준비 중이다.
