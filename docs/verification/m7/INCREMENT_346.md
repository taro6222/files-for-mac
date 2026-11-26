# M7 Increment 346 — 동일 원본의 선택 항목 추출 stream

상태: 별도 SDK helper의 추출 경계 구현·ARM 검증 완료. 앱 연결·staging 게시·취소/자원 격리·생성·최신 Intel native 추출 수용과 정식 출시는 미완료다.

## 구현

목록에서 연 동일 session/FD에 extract 요청을 추가했다. 요청은 session, 항목 index, expectedSize, maximumBytes를 받는다. SDK 메타데이터를 다시 읽어 regular file인지 확인하고 선언 크기와 일치해야 추출한다. maximumBytes는 기존 Core 기본 단일 파일 한도와 같은 최대 8,000,000,000바이트다. 실제 쓰기도 선언 크기를 넘지 않게 검사한다. 링크·디렉터리·기타 항목은 출력하지 않는다. 목록과 추출이 같은 메타데이터 분류 함수를 사용한다.

출력은 실행 시 `--output-fd N`으로 전달된 쓰기 전용 파이프만 허용한다. 읽기 전용 또는 regular 파일 descriptor로 임의 파일을 덮어쓰지 않는다. 아카이브 경로를 출력 경로로 사용하거나 SDK의 파일 생성 예제 코드를 연결하지 않는다. JSON 응답과 바이너리 데이터는 서로 다른 FD를 사용한다. 부모는 파이프를 동시에 읽어야 하며 SDK가 EOF/CRC/최종 결과를 보고한 뒤 성공 여부를 판정한다.

원본 크기·mtime·ctime을 추출 전후 확인한다. SDK의 실패·CRC 오류·비정상 길이·암호 누락/오류·출력 쓰기 실패는 성공으로 응답하지 않는다. 실패 응답 이전에 데이터 일부가 전달될 수 있다. 오류의 written은 완전히 수락한 SDK chunk의 합이며 파이프에 전달된 부분 쓰기의 정확한 합을 보장하지 않는다. 부모가 오류 시 stream 전체를 버리고 성공 시에만 검증된 staging을 게시하는 연결은 다음 단계다. 현재 앱의 7z password capability를 활성화하지 않았다.

## 검증과 근거

ARM native helper에서 기존 목록 34개 조건과 추출 25개 조건, 총 59개가 통과했다. 공식 참조로 만든 헤더 암호화 7z의 세 파일을 같은 session에서 선택 추출해 원문을 비교했다. 링크/디렉터리·크기 불일치·바이트 한도·잘못된 index/Boolean·출력 파이프 누락을 거부하고 거부된 항목 데이터가 추가되지 않았다. 추출 후 목록의 source identity도 유지됐다.

헤더를 암호화하지 않고 데이터만 암호화한 별도 fixture에서 암호 없이 목록을 열 수 있지만 추출은 누락/잘못된 암호 오류로 실패했다. 파이프 용량보다 큰 512KiB 데이터를 동시에 읽어 원문과 비교했고, 소비자를 닫으면 output-write로 실패했다. regular 출력 FD는 거부하고 기존 바이트를 보존했다. 헤더는 유지한 채 pack data를 변조한 7z는 목록이 열려도 최종 추출을 성공으로 표시하지 않았다. 목록 후 원본 변경은 출력 전에 거부했다.

두 CPU는 고정 소스에서 Wall/Wextra/Werror로 빌드하고 배포 메타데이터 14.0을 확인했다. Intel은 교차 빌드이며 native 추출 수용은 후속 CI에서 확인한다. [실행 조건과 빌드 해시](archive-stream-346-verification.json). Python 구문·workflow YAML·diff 검사도 통과했다. 앱/Core/Package/Xcode 소스는 유지해 기존 전체 UI/Release/Core를 반복하지 않았다. 기존 CI의 SDK 단계가 갱신된 59개 조건을 실행한다.

직전 2a1a7c7의 [CI 45775062986](https://github.com/taro6222/files-for-mac/actions/runs/45775062986)에서 macOS 15 ARM·Intel native SDK 빌드/목록 단계가 각각 성공했다. 다운로드한 두 실제 보고서의 34개 조건 전체를 확인했다. 확인 시점 전체 작업은 진행 중이므로 전체 CI 성공으로 표현하지 않는다. 이전 Intel Git scheduling·Spotlight EBUSY 실패도 해결 완료가 아니다.

인증서·공증 프로필은 사용자 준비 중이다. 안전한 Swift worker client·앱 연결, 7z 암호 생성 및 세부 옵션·분할, 원본 UI/실제 입력·VoiceOver·지원 환경/장시간·서명된 배포 수용은 남아 있다.
