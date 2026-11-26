# F23 압축 내부 편집 — 구현 및 수용 기준

현재 상태: **부분 구현·제품 연결 중·출시 전 해결 필요**. ArchiveCapabilityMatrix의 모든 update 값은 false이고 ArchiveWindow에는 내부 항목 추가/이름 변경/삭제 작업이 없다. 기존 MACOS_DESIGN의 임시 아카이브 교체 정책과 FEATURE_PARITY_AND_PLAN의 F23 수정 검증을 구체화한다. 새 범위를 추가하거나 기존 요구를 다음 버전으로 미루는 문서가 아니다.

[370단계](verification/m7/INCREMENT_370.md)에서 FD 기반 네이티브 ZIP/7z API를 부분 구현하고 실제 대응 소스/라이브러리로 83개를 통과했다. [371 구현 기록](verification/m7/INCREMENT_371.md)에서 실제 격리 helper IPC·공통 계획·Swift candidate 생성을 연결했다. [372 구현 기록](verification/m7/INCREMENT_372.md)에서 전체 내용·보존 속성·항목·암호화 및 source/output 변경 검증을 별도 읽기 전용 세션에 연결했다. 안전한 교체/복구·UI는 미연결이며 첫 개발 단위도 진행 중이다. 기존 Unicode AES ZIP의 metadata 편집은 통과했지만 새 암호 데이터 추가는 SDK 제한으로 미지원이다. 기존 Core AES writer 등을 이용한 브리지를 구현하기 전 update를 활성화하거나 기존 Unicode 암호 지원을 줄이지 않는다.

## 고정 원본과 현재 차이

기준 commit은 99951c66928c4da714da8b1dd46039421182cbab이다.

| 동작 | 원본 근거 | macOS 현재 |
|---|---|---|
| 내부 파일 추가 | [ZipStorageFolder.CreateFileAsync(Stream), 826행 이후](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Utils/Storage/StorageItems/ZipStorageFolder.cs#L826) | 네이티브 부분 구현·제품 미연결 |
| 내부 폴더 생성 | [CreateFolderAsync, 489행 이후](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Utils/Storage/StorageItems/ZipStorageFolder.cs#L489) | 네이티브 부분 구현·제품 미연결 |
| 파일 이름 변경 | [ZipStorageFile.RenameAsync, 518행 이후](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Utils/Storage/StorageItems/ZipStorageFile.cs#L518) | 네이티브 부분 구현·제품 미연결 |
| 폴더와 하위 경로 이름 변경 | [ZipStorageFolder.RenameAsync, 537행 이후](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Utils/Storage/StorageItems/ZipStorageFolder.cs#L537) | 네이티브 부분 구현·제품 미연결 |
| 내부 파일 삭제 | [ZipStorageFile.DeleteAsync, 569행 이후](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Utils/Storage/StorageItems/ZipStorageFile.cs#L569) | 네이티브 부분 구현·제품 미연결 |
| 폴더와 하위 항목 삭제 | [ZipStorageFolder.DeleteAsync, 591행 이후](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Utils/Storage/StorageItems/ZipStorageFolder.cs#L591) | 네이티브 부분 구현·제품 미연결 |

일반 파일 시스템의 Rename/Delete/Copy 명령이 implemented로 분류됐어도 압축 내부 문맥까지 구현됐다는 증거가 아니다. 202개 명령/143개 설정/33개 화면 인벤토리의 구조 감사와 이 동작 수용을 구분한다.

ZIP·단일 7z를 필수 구현 대상으로 한다. RAR 쓰기, 분할 기존 아카이브 편집 등은 원본의 실제 지원 조건을 별도로 확인하며 지원을 지어내지 않는다. 지원 여부를 확인하지 못한 포맷은 오류/읽기 전용 상태와 근거를 남긴다. 파일 추가·이름 변경·삭제를 모두 통과하기 전 update capability를 켜지 않는다.

## 엔진과 데이터 흐름

현재 고정 SDK의 Format7zF 라이브러리에는 ZIP writer도 빌드된다. 실제 제품 7z.so에서 ZIP과 7z 각각 IInArchive 인스턴스를 생성한 뒤 같은 인스턴스의 IOutArchive QueryInterface 성공을 확인했다. 이는 구현 가능성의 증거이며 실제 수정/암호/게시 동작의 통과 증거가 아니다.

공통 편집 계획은 원본 archive identity와 이전 item index, 작업 종류, 새 상대 경로, 추가 입력 스냅샷을 가진다. 폴더 이름 변경/삭제는 정확한 하위 경계로 확장하고 다른 접두어 폴더에 적용하지 않는다. 계획 전체의 결과 경로에 기존 ArchiveSecurity 정책을 적용해 절대 경로·이탈·중복·Unicode 충돌을 검사한다. 선택한 item index가 원본 스냅샷과 다르면 작업을 시작하지 않는다.

SDK는 기존 reader의 writer 인터페이스로 새 출력에 UpdateItems를 수행한다. 유지 항목은 기존 index를 참조하고, 이름 변경은 path property를 바꾸며, 삭제는 결과 계획에서 제외한다. 새 파일/폴더만 새 데이터/속성을 공급한다. ZIP과 7z를 동일한 어댑터 계약에서 선택하되 허용 enum 외의 임의 CLSID를 요청으로 받지 않는다.

원본과 추가 파일은 부모가 검증한 읽기 전용 FD만 전달한다. helper는 임의 원본/출력 경로를 열지 않는다. 계획은 기존 bounded frame/batch 계약을 재사용하고 세션·개수·순서·누락을 검사한 후 SDK 출력을 시작한다. 기존 App Sandbox·메모리 관찰·취소/기한·FD broker·서명/manifest 정책을 유지한다.

유지 항목의 내용·암호화·허용 metadata/설명을 보존한다. 기존 링크는 호스트 파일 시스템에 풀거나 따라가지 않고 codec의 metadata/stream으로 보존한다. 불명 항목을 조용히 누락하지 않는다. 솔리드 재압축처럼 encoded stream이 달라질 때에도 논리 내용의 동일성을 검사한다. 기존 암호화를 묵시적으로 해제하거나 낮추지 않으며 새 항목의 암호 정책도 명시한다. 암호는 로그·argv·설정에 저장하지 않는다.

## 게시·취소·복구

원본 archive는 편집 중 읽기 전용으로 유지한다. 같은 대상 디렉터리에 독점 생성한 private output FD로만 작성하고 종료·전체 항목·내용·metadata를 확인한 뒤 교체한다. 전체 파일을 호스트 임시 트리에 풀어 경로를 따라가는 방식이나 원본 archive stream 직접 덮어쓰기는 사용하지 않는다.

기존 파일 작업의 identity/백업/저널·Undo 규칙을 재사용한다. 게시 직전/직후에 원본·부모·출력 identity와 내용/metadata를 확인하고, 기존 원본은 복구 가능한 백업으로 보존한다. 단순한 exists 검사 뒤 rename을 조건부 교체라고 설명하지 않는다. 동시 교체를 발견하면 외부 데이터를 보존하고 소유 파일만 되돌린다. rollback도 충돌하면 복구 위치와 상태를 반환한다.

실패·취소·프로세스 종료가 출력 생성, codec, 검증, 백업, 게시의 어느 단계에서 발생했는지 저널에 구분한다. 게시 전에는 원본을 바꾸지 않는다. 게시 후 취소/Undo는 게시본과 백업이 당시 identity/내용을 유지할 때만 수행하며 사용자의 후속 변경을 덮지 않는다. 앱 재시작은 복구 상태를 표시하고 확인 없이 자료를 삭제하지 않는다.

## UI

ArchiveWindow에서 파일 추가·폴더 생성·이름 변경·삭제와 동일 기능의 문맥 메뉴/키보드 명령을 연결한다. capability/선택/실행 상태로 활성 조건을 통일한다. 폴더 하위 범위와 충돌 정책을 확인하고 암호·틀린 암호 재시도·취소를 기존 흐름에 연결한다. 작업 종료 후 변경된 목록과 선택/포커스를 복원한다. 새 오류/복구·Undo 상태는 한국어/영어와 접근성 안내를 포함한다.

## 개발 순서

1. 공통 편집 계획·FD 기반 SDK ZIP/7z 수정·출력 검증·안전한 교체/복구 서비스를 실제 왕복으로 구현한다. 아직 UI capability는 켜지 않는다.
2. 두 포맷의 암호/metadata/충돌/외부 변경/단계별 취소·재시작/Undo를 검증해 서비스의 미완료를 해소한다.
3. ArchiveWindow의 전체 동작·메뉴·단축키·충돌·암호·복구 상태를 연결하고 필요한 capability만 활성화한다.
4. 양 CPU native/Swift와 전체 AppKit/원본 문맥 대조를 검증하고 기존 F23 완료 여부를 판정한다.

각 개발 단위에서 관련 검증·문서·커밋·origin 푸시를 수행한다. GUI/장시간 시험은 기존 사용자 제약을 지키며 원격에서 필요한 GUI 검증을 한다. 현재 4a6c79d 전체 검증은 기존 기능의 기준선으로 보존하고 향후 편집 구현의 증거로 재사용하지 않는다.

## 필수 수용

- ZIP/7z의 파일 추가·빈 폴더 생성·파일/폴더 rename·파일/하위 트리 delete와 무관 항목 보존.
- Unicode/NFC/NFD·개행·대소문자·중복·prefix 경계·잘못된 index/경로·기존 링크 metadata 보존.
- 암호 ZIP/헤더 암호 7z·혼합 암호 상태·틀린 암호·재시도/취소와 암호 노출 0건.
- source archive/추가 입력/부모/게시본/백업의 외부 변경 및 동시 이름 교체에서 데이터 보존.
- 출력/codec/검증/백업/게시 각 단계의 오류·취소·강제 종료·재시작 복구와 Undo 충돌 보존.
- 기존 크기/개수/자원 한도와 남은 공간·읽기 전용 위치·지원 볼륨/OS·독립 도구 왕복.
- 원본의 해당 문맥과 실제 UI 조작·초점·비활성/진행/오류/복구·VoiceOver.

위 항목이 미완료이면 F23 수정 기능과 전체 출시를 완료로 표시하지 않는다.
