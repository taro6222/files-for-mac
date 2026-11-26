# M7 Increment 357 — 7z 생성 입력의 부모 FD 공급

상태: 일반/분할 생성 입력 FD 공급과 로컬 headless 검증 완료. helper 권한/자원 격리·메타데이터 복원·최신 원격 수용과 M7 정식 출시는 미완료다.

## 동작

제품 생성 프레임의 items에서 원본 절대 경로 source 필드를 제거했다. 상대 archive path와 기존 identity·크기·mode·mtime/ctime 스냅샷을 전달한다. SDK는 입력이 필요할 때 private 양방향 socket의 C marker와 32비트 big-endian index로 요청한다. 부모는 계획 범위/marker/완전한 프레임과 요청 예산을 검사한 뒤 해당 항목만 no-follow로 연다. 파일에는 읽기 전용 FD, 디렉터리에는 검색 전용 FD를 SCM_RIGHTS로 전달하며 전체 입력을 미리 열어 두지 않는다. 부모의 FD 제한은 변경하지 않는다.

SDK의 GetStream과 종료 전 재검증은 공급받은 FD만 사용한다. 실제 stat이 계획과 다르면 생성하지 않는다. 일반 파일은 pread로 읽어 공급자의 FD offset을 변경하거나 그 위치에 의존하지 않는다. 디렉터리 검증·정확한 읽은 크기·원본 변경 확인은 유지한다. 기존 path 기반 생성은 단독 진단 프로토콜 호환으로 남기지만 제품 호출은 사용하지 않는다.

부모의 응답 처리 루프는 생성 출력과 FD 요청을 함께 읽고 기존 기한/취소/PID 회수를 적용한다. 마지막 제어 채널 EOF를 확인해 잘린 FD 요청 뒤 성공 응답을 보내도 게시하지 않는다. 잘못된 index·marker·권리·외부 identity·쓰기 가능한 FD를 거부한다. 기존 단일 파일 no-replace 게시와 분할 part 저널·부분 게시 rollback·재시작 복구를 유지한다.

일반 생성은 입력 계획을 백그라운드에서 먼저 검증한 뒤 private 출력 파일을 만든다. 선택한 입력 폴더 내부 저장 위치는 원본 폴더의 파일 목록/수정 시각을 바꾸기 전에 거부한다. file URI의 NUL 거부와 signed device ID의 unsigned 표현도 계획/공급에 적용한다.

## 검증

- 최종 Release 번들의 실제 helper/library를 사용한 SDK·Swift·서명 검사 45개가 건너뜀 없이 8.120초에 통과했다. 새 검사는 계획 identity와 읽기 전용 FD, symlink 교체 거부, 300개 입력 생성/원문 복원과 부모 rlimit 보존, 입력 폴더 내부 출력의 목록/수정 시각 보존을 확인한다.
- 시험 helper의 잘못된 index/marker/잘린 5바이트 요청을 거부하고 게시 대상 부재·원본 내용·private 출력 제거를 확인했다. 기존 여섯 수준·암호·분할·취소·복구 회귀도 통과했다.
- 최종 번들의 native 경계 114개가 통과했다. 원본 이름이 삭제된 FD로 7z를 만들고 공식 7-Zip으로 원문을 복원했다. FD offset을 EOF 뒤로 놓아도 생성 결과가 같음을 확인한다. source 경로 혼용·잘못된 marker/권리·다른 inode·쓰기 가능한 입력을 거부하며 기존 읽기/분할/FD 예산 조건도 유지했다.
- 최종 Debug 7.56초(전체 브로커 Debug 18.10초), 최적화 Release 31.81초와 새 ad-hoc preview 번들의 서명/해시 검증이 통과했다. 임시 native 엔진·디버그 심볼 제외·CLT Testing.framework/호환 드라이버 설정은 유지했으며 저장소 빌드 스크립트는 변경하지 않았다.

[소스/결과/로그 해시](create-broker-357-verification.json)를 보존한다. 초기 새 검사 두 개의 /var 별칭과 /private/var 실제 경로 단언을 canonical fixture 기준으로 수정한 뒤 검증했다. 이는 생성 기능 실패나 원격 UI 수용 결과가 아니다. 로컬 GUI·전체 AppKit·장시간 시험은 실행하지 않았다.

## 남은 항목

부모 FD 공급은 helper의 전체 파일/네트워크 권한이나 메모리/CPU 격리의 완성을 뜻하지 않는다. 생성 계획의 기존 1 MiB 프레임 상한과 대용량/다수 입력 성능·자원 수용도 남아 있다. 이어서 helper 권한/자원 경계, 메타데이터 복원과 최신 두 CPU/지원 OS·실제 입력/VoiceOver·원본 UI 대조·정식 서명/공증을 진행한다. 인증서/프로필은 사용자 준비 중이다.
