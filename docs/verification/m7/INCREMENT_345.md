# M7 Increment 345 — 7z SDK 구조화 목록 helper

상태: 별도 helper의 list/close 경계 구현 및 ARM 검증 완료. 제품 연결·추출·생성·패키징·Intel native 실행과 M7 정식 출시는 미완료다.

## 구현

공식 7-Zip 26.06 대응 소스의 SHA-256을 고정해 Format7zF와 SDK 공통 객체를 빌드한다. SDK 타입과 Foundation 타입의 충돌을 피하도록 C 인터페이스로 C++ adapter와 Objective-C++ 프레임 처리를 나눴다. SDK의 item/property API에서 항목 인덱스·정확한 UTF-8 경로·종류·크기·암호화 여부를 읽는다. CLI 목록 텍스트를 제품 계약으로 파싱하지 않는다.

stdin/stdout은 UInt32 big-endian 길이와 version 1 JSON이다. 요청은 최대 1MiB, 응답은 최대 8MiB이며 항목 수는 최대 100,000이다. 명시한 키와 숫자 범위를 검사하고 Boolean을 정수로 허용하지 않는다. 최초 list는 archivePath와 선택 암호를 받으며 성공/목록 한도 오류에 session UUID를 반환한다. 후속 list와 close는 같은 session만 받는다. 목록의 경로는 신뢰되지 않은 메타데이터이며 현재 출력 파일을 생성하는 작업은 없다.

소스는 읽기 전용·비차단으로 열어 regular file만 허용한다. 같은 FD를 session 동안 유지하고 크기·mtime·ctime을 open/list 앞뒤에 비교한다. 원본 경로가 교체돼도 새 경로를 다시 열지 않는다. 내용 변경은 source-changed로 거부한다. 암호는 JSON private 입력으로 전달하며 인수/설정/저널/오류 문자열에 넣지 않는다. 메모리의 즉시 소거는 보장하지 않는다. 응답 한도는 SDK 헤더 디코더 자체의 메모리 한도가 아니며, 프로세스 시간·메모리 제한과 앱의 취소/종료 관리는 후속 구현 사항이다.

빌드는 소스·recipe·컴파일러·SDK·CPU·최소 OS의 fingerprint 경로에 게시한다. 실행한 경로를 재작성하지 않고 기존 캐시의 해시를 검사한다. SDK 소스는 압축 해시와 전체 크기를 확인하고 regular file/디렉터리만 추출한다. SDK License.txt와 manifest를 보존한다. 바이너리·다운로드 자산·소스 압축·캐시는 커밋하지 않는다. 제품의 서명된 SDK 번들/라이선스 배포 수용은 별도로 남아 있다.

## 검증

고정 공식 참조에서 plain 및 Unicode 암호/헤더 암호화 7z를 생성했다. ARM native helper로 암호 누락/오류/성공, 한글·이모지·실제 LF 파일명, 디렉터리/심볼릭 링크/파일 크기/암호 속성, source identity, 같은 세션 반복, close/EOF, 항목 한도 후 동일 세션 재시도, 잘못된 세션, 원본 내용 변경·경로 교체, FIFO/디렉터리 거부, Boolean 버전/한도·알 수 없는 키/작업·NUL 암호·과대/빈/잘린 프레임·잘못된 UTF-8, 원본 아카이브/입력 보존의 총 34개 조건이 통과했다.

두 CPU는 clang의 Wall/Wextra/Werror로 빌드됐다. Intel은 교차 빌드이며 이 Mac에서 실행하지 않았다. 양쪽 최소 배포 메타데이터 14.0을 확인했으며 macOS 14 실제 실행 수용은 아니다. [실행 결과와 빌드 해시](archive-worker-345-verification.json). 두 CPU native CI에 같은 SDK 빌드/프로토콜 검증을 추가했다. 실패 시 빌드 로그도 보존한다. Python 구문·workflow YAML·parity 구조 감사·diff 검사가 통과했다.

App/Core/Package/Xcode 소스는 유지해 기존 전체 UI/Core/Release를 반복하지 않았다. 원격 3e5c88f와 5f78d07은 ARM 전체 작업 성공·Intel 실패로 종료됐다. 3e5c88f Intel은 제한 Swift 실행기의 Git scheduling 단계, 5f78d07 Intel은 Spotlight 정리의 EBUSY로 실패했다. Spotlight 실패는 읽기 전용 최종 검사 전에 재시도를 소진한 경우이며 이미지/데이터를 보존한 실패다. 이 둘을 성공 또는 해결 완료로 처리하지 않는다. 331 고정 소스의 8시간 시험은 계속 실행 중이며 최종 수용이 아니다.

인증서·공증 프로필은 사용자 준비 중이다. 다음 구현은 안전한 추출 stream과 Swift worker client, 7z 암호 생성/추출 UI 연결이다. 분할·세부 옵션·서명된 패키징·원본 UI 대조·실제 입력/VoiceOver·지원 환경·성능/장시간 수용은 남아 있다.
