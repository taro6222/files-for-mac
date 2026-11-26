# 7z 고급 기능 백엔드 연결 계약

상태: 354단계에서 분할 생성·게시 저널/재시작 복구 API를 구현했다. [354단계 검증](verification/m7/INCREMENT_354.md)을 따른다. 생성 화면의 분할 크기 선택·복구 안내 연결·새 UI 원격 수용·메타데이터/자원 격리·정식 출시는 미완료다.

[345단계](verification/m7/INCREMENT_345.md)는 고정 SDK에서 두 CPU helper를 빌드하고 ARM에서 실제 암호화 아카이브와 프레임/동일 원본 검증 34개를 통과했다. `Tools/SevenZipWorker`의 UInt32 big-endian 길이 + JSON(version 1) list/close 경계로 시작했다. 최초 요청은 archivePath/password, 후속 요청은 session UUID를 사용한다. 목록 반복은 열린 FD를 유지하며 원본 변경은 거부한다. 소스 FD의 부모 전달은 아직 남아 있으며 제품 번들 포함은 후속 348단계에서 구현했다.

[346단계](verification/m7/INCREMENT_346.md)는 같은 session의 extract(index, expectedSize, maximumBytes)를 추가했다. 실행 시 `--output-fd N`으로 전달된 쓰기 전용 파이프에만 파일 데이터를 보내며 아카이브 경로로 출력 파일을 열지 않는다. 단일 파일 한도는 기존 Core 기본 한도와 같은 8,000,000,000바이트다. regular item·선언 크기·상한·원본 변경·SDK 최종 CRC/오류 결과를 검사한다. 응답의 written은 성공 시 정확한 크기이며 실패 시 일부 출력이 존재할 수 있다. 부모는 실패한 stream 전체를 버려야 한다. 346단계의 단독 helper에서 제품의 경로/총량 검증·staging 게시·취소 연결은 후속 사항이었으며 아래 347단계에서 일부를 연결했다. 메모리/권한 격리는 계속 남아 있다.

[347단계](verification/m7/INCREMENT_347.md)의 SevenZipArchiveProvider는 private 파이프·버전/길이/형식·수명·IPC 기한·취소 후 PID 회수와 Core 경로/총량 검증을 연결했다. descriptor 기준으로 staging을 만들고 모든 파일·최종 helper 종료를 확인한 뒤 하나의 새 폴더를 RENAME_EXCL로 게시한다. 충돌은 보존하고 다른 항목이 끼어든 staging은 삭제하지 않으며 stagingPreserved(URL)로 위치를 반환한다. 여기/스마트 병합 게시·UI 암호 흐름·기존 메타데이터 복원·helper의 메모리/권한 격리·서명된 패키징은 후속 단계다. helper와 소스 FD는 session 동안 유지하며 sourcePath를 다시 열어 추출하지 않는다.

[348단계](verification/m7/INCREMENT_348.md)는 Helpers/SevenZipWorker와 Frameworks/7z.so를 앱과 같은 CPU 구성으로 포함하고 라이브러리 → helper → 앱 순으로 서명한다. Resources/ThirdParty/7zip에는 원본 License/copying/unRarLicense/readme, 고정 원본 소스 archive와 helper/빌드 소스·재빌드 자료·manifest를 포함한다. SDK의 라이브러리 ID는 @rpath/7z.so로 정리하며 부모는 명시한 경로로 로드한다. 새 유니버설 DMG에서 구성/고지/소스/서명과 native SDK 59개·Swift 9개를 확인했다. 347 ARM CI의 invalidResponse를 조사해 빈 진단 파이프 EOF를 데이터로 오인하는 경로를 실제로 재현하고 수정했다. 최신 두 CPU native 재수용·제품 UI 연결·메모리/권한 격리·Developer ID/공증은 계속 남아 있다.

[349단계](verification/m7/INCREMENT_349.md)는 `SevenZipArchiveProvider.bundled(in:)`를 추가했다. native Security API와 CryptoKit으로 앱/두 구성 요소의 서명·역할 identifier·Team 정책, 고정 경로/파일 집합·manifest·source pin·hash를 검증한다. preview에서만 ad-hoc을 허용하고 stable/non-ad-hoc에는 Developer ID requirement와 동일 Team을 요구한다. 앱으로부터 받은 경로를 다시 찾거나 PATH/Python을 실행하지 않는다. 반환 provider도 매번 원본 bundle을 재검증한 뒤 worker를 생성한다. 정상 signature의 잘못된 identifier·재서명한 hash/source pin 변경·선택 후 변조를 거부했고 실제 번들에서 암호 7z를 복원했다. 현재 ArchiveWindow/일괄 추출 UI는 여전히 기존 provider를 사용한다. 여기/스마트 배치의 게시·UI 선택·메타데이터/자원 제한과 최신 두 CPU resolver 수용이 남아 있다.

선택한 CodeDirectory/manifest identity를 provider에 고정한다. 다른 유효한 재서명 번들도 기존 provider에서 자동으로 채택하지 않는다. 현재 앱 자체를 선택하면 실행 중인 호스트도 해당 designated requirement를 만족해야 하며 코드 메타데이터는 현재 프로세스 CPU로 조회한다. 이 검증과 posix_spawn/dlopen을 하나의 원자적 연산으로 만든 것은 아니며 악의적인 동시 교체의 전체 차단·자원 격리는 별도 수용 항목이다. 실제 Developer ID 인증서/공증 수용도 아직 남아 있다.

[350단계](verification/m7/INCREMENT_350.md)는 ArchiveWindow와 일괄 추출의 7z 경로를 이 factory에 연결했다. 헤더 암호화는 목록 열기에 암호를 요청하고, 데이터 추출은 기존 here/smart/child 배치를 유지한다. 기존 폴더에는 top-level별 no-replace 게시 후 실패/취소 시 소유 항목을 되돌린다. 변경된 게시 항목은 보존하고 recovery 위치를 반환한다. 여러 이름의 게시가 단일 원자적 동작인 것은 아니다. 지원 창은 ZIP의 암호 생성/추출과 7z의 확인된 암호 추출을 구분한다. 기존 password Bool은 완전한 생성/추출 지원을 뜻하므로 7z에서 false를 유지한다. UI 실행 수용은 아직 대기 중이며 SDK 없는 개발 실행은 기존 libarchive의 일반 7z 경로를 유지한다.

근거는 [344단계](verification/m7/INCREMENT_344.md)의 실행 결과와 [원본 옵션 대응표](reference/ARCHIVE_OPTIONS_PARITY.md)다. 공식 7-Zip 26.06의 macOS ARM·Intel 자산, 대응 소스와 SHA-256을 고정한다. [공식 다운로드](https://www.7-zip.org/download.html)에서 연결되는 ip7z/7zip 릴리스를 사용한다. 획득 코드는 [sevenzip_reference.py](../scripts/sevenzip_reference.py)에 있으며 전역 설치 없이 build 아래에 저장한다. 공식 7zz 실행 파일은 검증 도구이고 앱에는 자체 빌드한 SDK helper/라이브러리를 포함한다. 앱 UI에서의 SDK 선택·호출은 아직 연결하지 않았다.

## 경계와 프로토콜

기존 libarchive의 ZIP AES-256·안전한 추출 검증을 유지하며 7z 고급 기능은 SDK 기반 별도 helper로 연결한다. SDK 대응 소스와 빌드/패치를 고정하고 양쪽 CPU·최소 macOS에서 검증한다. Foundation JSON을 사용할 수 있는 native helper와 7-Zip SDK의 구조화된 item/property API를 이용한다. CLI의 .slt 텍스트는 현재 알려진 fixture의 옵션 확인 자료이며, 제품의 임의 경로 목록 계약은 구조화된 API로 구현한다.

worker의 입출력은 버전과 길이가 있는 프레임으로 정의한다. 요청에는 작업 ID·옵션·원본 descriptor와 암호 전달 채널을 포함하고, 응답에는 항목 인덱스·정확한 Unicode 경로·종류·크기·암호화 여부·진행·형식화된 오류를 담는다. 암호는 stdin/private descriptor로 전달하고 인수·설정·저널·로그에서 제외한다. 스트림/worker의 종료를 기다린 뒤 UI 입력과 작업 참조를 정리한다. Swift/C 메모리의 즉시 소거는 별도 증거 없이 보장하지 않는다.

목록과 추출은 동일하게 열린 원본을 사용해 파일 교체 경계를 관리한다. Core의 경로·링크·크기/항목 수 한도 검증 후에만 regular file의 데이터를 받는다. 생성/추출 출력은 Core가 연 staging stream 또는 검증된 프레임으로 전달하고, archive 내부 경로가 최종 대상 경로를 직접 선택하지 않게 한다. 손상·암호 오류·누락 볼륨·취소는 사용자 데이터 게시 전 실패 경로로 연결한다.

## 분할 게시와 복구

선택 폴더에 원본처럼 여러 분할 파일을 배치한다. 파일 집합의 게시를 단일 파일 rename처럼 원자적이라고 표현하지 않는다. 모든 staging part를 검증하고 목적지 충돌을 확인한 뒤, part별 게시·identity·해시를 저널에 기록한다. 중간 실패/재기동에서는 자신이 게시한 동일 결과만 복구하며 외부 교체 항목은 보존한다. 모든 part의 검증·게시가 끝났을 때 전체 성공으로 표시한다. 암호는 복구 저널에 저장하지 않는다.

누락 part와 이름 변경·기존 part 충돌·동시 쓰기·게시 직후 종료·변경된 게시 part·부족한 공간·사용자 취소를 실제 fixture로 수용한다. 원본과 같은 폴더 내 part 배치를 수용 기준으로 유지한다.

## 패키징과 수용 순서

1. 고정 SDK 소스에서 helper와 구조화된 목록/추출 프로토콜을 구현한다. 임의 Unicode·줄바꿈 경로·잘못된 프레임·손상 입력·제한 초과를 검증한다.
2. 암호 7z 생성·목록·추출을 하나의 사용자 흐름으로 연결한다. 다음으로 분할·사전/워드 크기·스레드 옵션과 검증된 메모리 추정을 연결한다.
3. 두 아키텍처 helper를 앱의 private 위치에 포함하고 helper와 앱을 서명한다. 원본 License.txt 및 대응 소스/패치·재현 가능한 빌드 정보를 배포 산출물에 포함하도록 내용물 검증을 추가한다. 바이너리 자산은 Git에 커밋하지 않는다.
4. 실제 설치된 앱의 두 CPU·최소 OS·다른 구현 왕복·원본 UI 상태·키보드/VoiceOver·취소/충돌/복구·자원/장시간 검증 후 capability를 활성화한다.

344단계의 요청 스레드 수는 실제 스레드 사용량 측정이 아니며, 기준 도구 실행 성공은 제품 백엔드의 연결·복구·배포 수용을 대신하지 않는다.

[351단계](verification/m7/INCREMENT_351.md)의 `--create-output-fd N`은 부모가 독점 생성한 빈 일반 파일 FD를 받는다. create 요청은 원본 identity/크기/mtime/ctime/mode 및 아카이브 상대 경로, 압축 수준, 암호와 파일 이름 암호화 여부를 담는다. 기존 1 MiB 요청 한도를 유지한다. helper는 출력 경로를 열지 않고 모든 입력 구성요소에서 링크를 거부하며 읽기/완료 후 원본을 재검증한다. 부모는 정상 종료 뒤 원본·임시 출력·부모 identity를 다시 확인해 RENAME_EXCL로 게시한다. 암호와 헤더 암호화는 Unicode를 지원한다. 현재 SDK 스레드는 2개를 요청하며 고급 옵션·자원 격리·실제 두 CPU UI 수용은 별도 항목이다.

[352단계](verification/m7/INCREMENT_352.md)는 dictionarySize/wordSize/threads를 추가하고 양쪽 범위 검증 및 SDK 0=LZMA2/0d/0fb/mt 속성에 연결했다. 자동 사전은 고정 원본 Files의 수준별 기본값을 명시적으로 전달한다. 옵션과 형식을 저장/복원하며 예상 메모리는 원본 근사식, 사용 가능 메모리는 현재 free+inactive 페이지로 표시한다. 실제 스레드/RSS와 자원 격리·분할·새 UI 수용은 미완료다.

[353단계](verification/m7/INCREMENT_353.md)는 최초 list의 archivePaths 배열(최대 1,024개·8 GB)과 같은 FD를 유지하는 seekable 연결 스트림을 추가했다. 기존 archivePath와 동시 지정은 거부한다. source.size는 전체 바이트 수다. 중간 누락은 부모가 검사하고 유효 start header의 CRC/선언 길이와 SDK physical size로 마지막 누락/잘림·불필요한 후속 데이터를 거부한다. missing-volume 오류를 추가했다. helper의 FD soft limit만 필요 시 조정하고 부모 제한은 바꾸지 않는다. 원본 FD의 부모 전달·분할 생성/저널·자원 격리·최신 두 CPU/실제 UI 수용은 남아 있다.

[분할 7z 생성과 재시작 복구](verification/m7/INCREMENT_354.md)는 전체 임시 아카이브 없이 위치 지정 출력 스트림을 part로 나누고, private 저널·identity/해시·게시 의도와 충돌/취소 rollback을 구현했다. 생성·복구 API의 headless 검증을 마쳤으며 생성 화면의 분할 크기 선택·복구 안내 연결과 최신 원격/지원 환경·정식 출시는 미완료다. 로컬 GUI/장시간 시험은 재시작하지 않았다.

분할 출력은 `--create-stream-fd` 전용 쓰기 파이프의 17바이트 위치 지정 프레임(write/truncate/end)을 사용한다. 일반 생성의 빈 regular FD 계약은 유지한다. 부모가 같은 대상 폴더의 private staging에 직접 part를 만들고, 최종 7z 헤더/길이·각 part의 SHA-256·identity를 확인한 뒤 RENAME_EXCL로 게시한다. private `archive-splits` 저널은 게시 의도를 rename 전에 fsync하고, 재시작 시 확인 가능한 부분 게시만 되돌린다. 모호한 의도·변경 파일·손상 저널은 보존한다. 전체 게시가 하나의 원자적 연산이라는 보장은 없으며 실제 전원 장애/외부 파일 시스템 수용은 별도다. 분할 크기 설정은 16바이트~23,040 MiB, 실제 출력은 합계 8,000,000,000바이트·1,024 part 한도를 유지한다.
