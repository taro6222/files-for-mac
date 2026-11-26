# 7z 고급 기능 백엔드 연결 계약

상태: 공식 도구 획득·독립 호환성/옵션 검증 및 SDK helper의 구조화된 목록·선택 항목 추출 경계 구현 완료. 앱 연결·생성은 진행 예정이며 현재 제품의 7z 암호·분할 capability는 미지원이다.

[345단계](verification/m7/INCREMENT_345.md)는 고정 SDK에서 두 CPU helper를 빌드하고 ARM에서 실제 암호화 아카이브와 프레임/동일 원본 검증 34개를 통과했다. `Tools/SevenZipWorker`는 UInt32 big-endian 길이 + JSON(version 1)의 list/close만 구현한다. 최초 요청은 archivePath/password, 후속 요청은 session UUID를 사용한다. 목록 반복은 열린 FD를 유지하며 원본 변경은 거부한다. 현재는 private stdin 경계이며 앱의 descriptor 전달·추출 출력 stream·취소·자원 격리 계약은 아직 구현하지 않았다. 제품 번들에 포함하지 않았다.

[346단계](verification/m7/INCREMENT_346.md)는 같은 session의 extract(index, expectedSize, maximumBytes)를 추가했다. 실행 시 `--output-fd N`으로 전달된 쓰기 전용 파이프에만 파일 데이터를 보내며 아카이브 경로로 출력 파일을 열지 않는다. 단일 파일 한도는 기존 Core 기본 한도와 같은 8,000,000,000바이트다. regular item·선언 크기·상한·원본 변경·SDK 최종 CRC/오류 결과를 검사한다. 응답의 written은 성공 시 정확한 크기이며 실패 시 일부 출력이 존재할 수 있다. 부모는 실패한 stream 전체를 버려야 한다. 제품의 전체 경로/총량 검증·staging 게시·취소·시간/메모리 격리 연결은 아직 남아 있다.

근거는 [344단계](verification/m7/INCREMENT_344.md)의 실행 결과와 [원본 옵션 대응표](reference/ARCHIVE_OPTIONS_PARITY.md)다. 공식 7-Zip 26.06의 macOS ARM·Intel 자산, 대응 소스와 SHA-256을 고정한다. [공식 다운로드](https://www.7-zip.org/download.html)에서 연결되는 ip7z/7zip 릴리스를 사용한다. 획득 코드는 [sevenzip_reference.py](../scripts/sevenzip_reference.py)에 있으며 전역 설치 없이 build 아래에 저장한다. 현재 실행 파일은 검증 도구이며 앱 번들에는 연결하지 않았다.

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
