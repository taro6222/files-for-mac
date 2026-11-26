# M7 Increment 356 — 7z 읽기 원본의 부모 FD 브로커

상태: 탐색·추출 FD 브로커 구현과 로컬 headless 검증 완료. 생성 입력·SDK 권한/자원 격리·메타데이터·최신 원격 수용과 M7 정식 출시는 미완료다.

## 동작

부모는 선택한 압축 파일의 실제 폴더를 검색 전용 O_SEARCH·O_NOFOLLOW_ANY로 열고, regular 입력을 O_RDONLY·O_NOFOLLOW로 한 번에 하나씩 연다. 여러 분할 볼륨도 부모 FD 한도를 올리지 않고 private AF_UNIX socketpair의 SCM_RIGHTS로 전달한다. 파일이 있는 폴더를 읽어 나열할 권한 없이 탐색/파일 읽기만 허용된 단일 아카이브도 처리한다. 사용자가 선택한 단일 symlink는 실제 대상을 고정하고, 분할 part symlink 거부는 유지한다.

제품 list 프레임에는 원본 경로 대신 sourceFDs 스냅샷 배열(device/inode/size/mode/mtime/ctime)과 splitVolumes를 담는다. 소켓 메시지는 F marker·FD 한 개를 순서대로 보내고 마지막 EOF를 요구한다. 부모의 비차단 전송은 기존 기한·취소/자식 PID 회수를 사용한다. 디코더는 AF_UNIX stream 채널·권리 수·regular/read-only 타입·CLOEXEC·스냅샷을 확인한 후 SDK에 넘긴다. 경로 필드 혼용·잘못된 marker/권리·후속 데이터는 거부한다.

SDK는 수신 FD를 다시 복제하지 않고 소유권을 받아 같은 열린 파일로 목록과 추출을 수행한다. 소유권을 넘긴 배열 슬롯을 -1로 바꿔 오류/정상 종료에서 이중 close와 남은 FD 누락을 피한다. 자식 한도는 기존 count+64 예산만 사용하며 부모 한도는 변경하지 않는다. 부모는 목록 응답 후·디코더 정상 종료 후·게시 직전에 원래 폴더의 identity와 입력 항목의 identity·mode·size·mtime/ctime을 확인한다. 폴더나 이름이 교체되면 다른 파일을 읽어 출력을 게시하지 않고 변경 오류로 중단한다.

진단용 기존 path 기반 helper 프로토콜은 기존 native 검사 호환용으로 남긴다. 제품의 탐색·추출은 이를 사용하거나 오래된 helper로 자동 fallback하지 않는다. 생성 입력은 아직 기존 경로와 source plan 검증을 사용한다. 읽기 전용 FD 전달은 helper 전체 파일/네트워크 권한·메모리/CPU 격리의 완성을 의미하지 않는다.

## 검증

- 최종 Release 번들의 실제 helper/library로 Swift·SDK·서명 검사 42개가 건너뜀 없이 7.630초에 통과했다. 생성·암호·옵션·분할·재시작 복구·번들 선택 회귀를 포함한다.
- 새 브로커 검사는 부모 폴더를 교체해도 pinned 폴더의 파일만 열고 최종 변경을 거부함을 확인한다. symlink 입력·탐색 전용 폴더의 실제 암호 목록과 signed device ID의 unsigned 전달도 확인한다. 기존 256개 초과 tiny 볼륨과 부모 rlimit 보존 검사도 통과한다.
- 최종 번들의 native 경계 107개가 통과했다. 이름이 삭제된 원본 FD의 목록/원문 추출, 잘못된 메타데이터·권리·marker·후속 데이터·채널/읽기 권한을 거부한다. 자식 hard FD limit 128에서 32개 초과 분할 볼륨을 실제 목록/추출하고 원문을 비교했다. 기존 91개 조건도 유지했다.
- 최종 Debug 2.50초(앞선 전체 브로커 Debug 18.23초), 최적화 Release 31.72초와 새 ad-hoc preview 번들의 서명/해시 검증이 통과했다. native 엔진/디버그 심볼 제외와 Debug의 호환 드라이버·CLT Testing.framework 경로는 355단계의 임시 명령 설정을 재사용했다. 저장소 빌드 스크립트는 변경하지 않았다.

[소스와 결과/로그 해시](read-broker-356-verification.json)를 보존한다. 로컬 GUI·전체 AppKit·장시간 시험은 실행하지 않았다. 355 소스의 원격 실행 45813136385는 마지막 확인에서 ARM·Intel 모두 전체 AppKit suite 단계다. 아직 성공으로 집계하지 않으며 356 소스의 원격 수용으로 대신하지 않는다.

## 다음 구현

생성 입력을 부모 FD 공급으로 연결한 뒤 helper의 파일/네트워크 권한과 자원 경계를 구현한다. 메타데이터 복원, 실제 큰 파일/외부 파일 시스템·지원 OS/CPU·최신 원격 UI·실제 입력/VoiceOver와 정식 서명/공증도 열린 항목이다. 인증서/프로필은 사용자 준비 중이다.
