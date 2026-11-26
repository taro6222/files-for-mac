# 373 — 압축 저장·백업·Undo·재시작 복구 API, F23 진행 중

검증된 편집본을 원본과 교체하는 Core API를 연결했다. **편집 UI와 복구 기록 화면, Unicode 암호 ZIP의 새 데이터 추가, 전체 지원 환경 수용은 아직 남아 있다.** update capability는 false다.

## 저장과 실행 취소

`SevenZipArchiveProvider.edit`는 같은 부모의 private 0700 staging에 별도 출력 FD를 만들고 372의 전체 편집본 검증을 통과시킨다. 원본의 권한·소유자·ACL·확장 속성·리소스 포크·파일 플래그·생성 시각을 출력에 복사하고 확인한다. archive의 수정 시각은 저장 시각으로 갱신한다. 일반 metadata 복사가 생성 시각의 정밀도를 그대로 보존하지 못하는 실제 실패를 확인했으며 FD 기반 fsetattrlist로 원래 시각을 복원한 뒤 다시 비교한다.

원본/편집본의 전체 주 데이터 fork SHA-256과 inode·device·크기·mode·소유자·link 수·mtime/ctime, 외부 metadata 및 부모/staging의 identity를 교체 전에 재검증한다. 원본과 출력·기록·부모 디렉터리를 fsync한다. `RENAME_SWAP`으로 두 완성 파일을 교환해 이전 원본을 private staging의 백업으로 남긴다. 교환 뒤에는 rename 자체의 ctime 변경만 허용하고 두 파일의 내용·다른 속성·위치를 다시 확인한다. 교환 이후 오류에는 journal·archive·보존 파일의 위치를 반환한다. 외부에서 경합한 파일이나 백업을 삭제하지 않는다.

Undo는 현재 archive와 백업이 기록된 두 파일인지 다시 확인하고 같은 교환으로 복원한다. 수정본도 private 위치에 남는다. 완료된 Undo의 재호출은 같은 상태를 검증해 반환한다. 이 API에 Redo와 화면의 UndoManager 연결은 아직 없다.

## 기록과 프로세스 중단 복구

private `archive-edits/UUID/`의 이벤트는 고유 순번에 no-overwrite 게시한다. 각 payload의 SHA-256 체크섬과 이전 이벤트의 digest를 연결하며 기존 이벤트를 덮어쓰지 않는다. private registry가 복구의 신뢰 경계이며 같은 사용자 권한으로 기록을 바꿀 수 있는 코드를 인증하는 장치는 아니다. 기록은 암호·입력 내용·복호화한 member 목록을 저장하지 않는다.

`building → prepared → swapIntent → committed` 및 `undoIntent → undone`을 기록한다. 별도 프로세스의 `recoverArchiveEdit`는 실제 두 파일의 위치·내용·metadata와 의도를 비교해 미게시·저장 완료·Undo 완료를 판정한다. 일반 복구 호출은 archive를 교환하지 않는다. Undo 요청에서만 파일을 교환한다. 파일 변경·손상된 JSON·체크섬/체인 불일치·부모/staging 교체·다른 활성 작업의 잠금은 자동 덮어쓰기 없이 거부한다. 파일 이름별 advisory lock은 실행 중인 제품 작업끼리 직렬화하며 외부 프로그램의 쓰기를 차단한다고 주장하지 않는다.

취소는 교환 직전까지 확인한다. 교환을 끝낸 후에는 두 파일 검증과 완료 기록을 마치는 안전 지점을 따른다. metadata 복사도 즉시 중단 가능한 streaming API라고 표시하지 않는다. 실패·취소된 출력과 기록은 보존되며 현재 UI의 자동 정리/재시도 목록에는 아직 연결하지 않았다.

## 최종 검증

| 범위 | 결과 |
|---|---|
| Debug / Release | 14.32초 / 33.98초 빌드 통과 |
| Swift 클라이언트·번들 | 68개 통과 |
| 실제 격리 helper / 비격리 진단 | 113개 / 205개 통과 |
| native 편집 / OS 권한 probe | 83개 / 15개 통과 |

비암호 ZIP/7z, ASCII 암호 ZIP 및 Unicode/헤더 암호 7z의 실제 저장·백업·Undo를 확인했다. 새 항목 추가/이름 변경 결과는 공식 7-Zip으로 복원했다. 실제 ACL 규칙·UF_NODUMP·확장 속성·리소스 포크·권한·생성 시각을 보존했고 외부 archive/백업/metadata 변경 및 기록/마지막 체크섬 손상을 거부하며 해당 파일을 보존했다.

시험 전용 CLI 자식을 저장 교환 전/후와 Undo 교환 전/후에 `_exit(75)`로 종료하고 새로운 프로세스로 네 위치를 복구했다. 교환 전 취소는 원본과 검증된 편집본을 모두 보존하며 미게시 상태로 재확인했다. 첫 코드의 ACL 없음 처리와 생성 시각 실패 및 수정 결과는 `build/edit-373-*.log`에 보존했다. probe는 앱 번들에 포함하지 않는다.

[최종 소스·보고서 검증 기록](archive-transaction-373.json). 로컬 GUI·전체 AppKit·장시간 시험 앱은 실행하지 않았다.

## 아직 완료하지 않은 항목

현재 저장 API는 로컬 APFS에서 검증했다. RENAME_SWAP을 지원하지 않는 파일 시스템의 대체 게시와 실제 다른 볼륨/OS 수용은 남아 있다. decmpfs 압축 파일의 저장 metadata를 새 내용에 복사하면 다른 데이터로 해석될 수 있어 현재 해당 원본은 변경 전에 거부한다. 압축·immutable/append 플래그의 전용 처리도 이 변경에서 완료하지 않았다. 이를 F23의 최종 지원 범위 축소로 확정하지 않는다.

Redo·기록 목록/실패 출력 정리·편집 화면·Unicode 암호 ZIP 새 payload 브리지·mixed/solid/최대 규모 및 최신 양 CPU 수용이 남아 있다. 기존 371 원격 실행 45860713694는 관찰 당시 진행 중, 372 실행 45863201164는 pending이었다. 이번 로컬 통과를 원격 전체 통과로 집계하지 않는다. F23/M7 정식 출시는 미완료이며 인증서/공증 프로필은 사용자 준비 중이다.
