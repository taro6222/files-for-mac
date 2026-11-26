# M7 Increment 347 — Swift SDK 클라이언트와 안전한 새 폴더 게시

상태: Core 서비스 구현·ARM 통합 검증 완료. 제품 UI·패키징·배치별 게시·메타데이터·최신 Intel Swift 클라이언트 수용과 정식 출시는 미완료다.

## 동작

SevenZipArchiveProvider는 고정 SDK helper를 명시한 위치에서 실행하고 비동기 목록/새 폴더 추출 API를 제공한다. 프로세스 생성과 blocking POSIX 작업은 Swift 협력 실행기 밖의 Dispatch 작업에서 수행한다. posix_spawn file actions로 stdin 요청·stdout 응답·stderr 진단·별도 FD 3의 데이터 파이프를 연결한다. 다른 descriptor는 상속하지 않고 환경도 locale/PATH로 한정한다. 암호는 private 요청에만 넣는다.

응답/데이터 파이프를 poll로 함께 읽어 파이프 용량보다 큰 파일도 교착 없이 처리한다. 요청 1MiB·응답 8MiB, 버전/타입/연속 index/종류/크기/session을 검사한다. 예기치 않은 진단·추가 출력·종료 오류는 성공으로 처리하지 않는다. 알려진 SDK 오류 코드만 오류로 전달해 임의 진단 문자열을 노출하지 않는다. IPC에는 시작 시간을 포함한 전체 기한이 있고 취소·시간 초과·오류 시 소유한 PID만 종료하고 waitpid로 회수한 뒤 완료한다. PID 회수와 취소를 lock으로 직렬화해 회수한 PID에 뒤늦게 signal을 보내지 않는다. 파일 시스템 호출 자체의 강제 중단이나 메모리의 즉시 소거를 보장하지 않는다.

목록은 추출까지 같은 session/원본 FD를 유지한다. 기존 Core validator로 전체 경로·링크·중복·개별/총 크기를 먼저 확인한다. 검증 후 목적지 부모의 FD와 staging root FD를 열고, openat/mkdirat 및 O_NOFOLLOW/O_EXCL로 디렉터리와 일반 파일만 만든다. 부모 파이프에서도 선언 크기를 넘는 데이터는 거부한다. 성공 응답의 실제 크기·모든 항목·최종 helper close와 정상 종료를 확인한다.

게시 전 기록한 항목 identity·일반 파일 크기/mtime/ctime과 전체 디렉터리 항목을 다시 대조한다. parent/root identity를 확인한 뒤 descriptor-relative RENAME_EXCL로 하나의 새 디렉터리를 게시한다. 기존 대상·심볼릭 링크·게시 직전 충돌은 덮어쓰지 않는다. 현재 파일 시스템이 이 no-replace 연산을 지원하지 않으면 실패하며 약한 경로 기반 대체로 진행하지 않는다. 전원 장애에 대한 fsync/저널 복구를 수용한 것은 아니다.

오류/취소 시 자신이 기록한 항목만 있는 staging을 정리한다. 다른 항목이나 교체된 identity가 발견되면 삭제하지 않고 stagingPreserved(URL) 오류로 보존 위치를 반환한다. 이 서비스는 현재 새 디렉터리 게시 전용이며 기존 디렉터리로의 여기/스마트 병합은 아직 없다. 출력은 0700 디렉터리·0600 파일로 시작하고 원본 mode/time/ACL 복원은 후속 단계다. 앱 메뉴나 capability를 이 단계에서 활성화하지 않았다.

## 검증

신규 Swift 검사 8개가 통과했다. 실제 실행은 다음을 확인한다.

- 과대/잘린 프레임·Boolean 버전·알 수 없는 오류/종류·예기치 않은 stderr 거부, 바이트 단위로 나뉜 응답과 정상 close.
- 전체 기한 초과, 실제 PID marker를 확인한 후 취소·회수. 짧은 기한은 interpreter가 marker를 쓰기 전에도 만료될 수 있으므로 marker 생성을 시간 초과 성공의 전제로 두지 않는다. 취소 경로에서는 marker와 종료 후 ESRCH를 필수 확인한다.
- 경로 이탈/절대 경로를 staging 생성 전에 거부.
- 공식 도구가 생성한 Unicode 암호/헤더 암호화 7z의 목록·512KiB와 실제 LF/한글/emoji 이름의 원문 복원·새 폴더 게시.
- 틀린/누락 암호·기존 대상·총량 제한·손상된 pack data·심볼릭 링크에서 미게시와 staging 정리.
- 게시 직전 외부 대상 보존, staging에 추가한 합성 외부 파일과 보존 위치 반환, 게시 직전 취소 후 미게시/정리.

참조와 worker를 활성화한 Core 전체는 404개 중 성공 385개·환경 건너뜀 19개로 통과했다. Debug 앱/테스트 빌드가 통과했다. Release는 컴파일·링크 후 dSYM 생성에서 sandbox Operation not permitted로 실패했고, 같은 명령을 권한 제한 밖에서 재실행해 통과했다. Python 구문·workflow YAML·parity 구조 감사·diff 검사도 통과했다. [조건별 결과·소스/도구 해시](archive-client-347-verification.json).

새 필수 CI 게이트는 native worker/reference를 실제로 전달해 8개 함수가 모두 성공했는지 확인하며 건너뜀이나 보고 누락을 허용하지 않는다. 보고서와 로그를 두 CPU별 artifact로 남긴다. Spotlight 정리 게이트의 명령/기한/검사 조건은 유지하고 SDK 클라이언트 뒤로 옮겨 각 독립 경계의 결과를 수집한다. 이전 정리 실패를 수정하거나 성공으로 바꾼 조치가 아니다.

직전 06f50f8의 [CI 45775586448](https://github.com/taro6222/files-for-mac/actions/runs/45775586448)에서 macOS 15 ARM·Intel SDK 목록/추출 59개가 각각 통과했고 두 실제 보고서를 내려받아 확인했다. 전체 Intel 작업은 Spotlight 미마운트 정리에서 실패했다. 확인 시점 ARM 전체 작업은 진행 중이었다. 이 결과는 새 Swift 클라이언트의 Intel native 수용을 대신하지 않는다.

앱 UI·기존 ZIP 경로는 유지해 기존 AppKit 전체 UI를 반복하지 않았다. 331 고정 소스의 기존 8시간 프로세스도 같은 handle에서 살아 있음을 확인했으며 완료 판정은 아니다. 인증서·공증 프로필은 사용자 준비 중이다. 다음은 private helper 패키징·앱 배치/암호 흐름 연결이며 메타데이터·7z 생성/세부 옵션/분할·자원 격리·원본 UI/물리 입력/VoiceOver·지원 환경/최신 장시간 검증과 정식 출시는 남아 있다.
