# 370단계 — 압축 편집 네이티브 API 부분 구현

## 구현 범위

고정 SDK의 ZIP/7z reader와 같은 객체의 IOutArchive를 연결했다. SevenZipOpenEditDescriptor는 읽기 전용 archive FD를 채택하며 포맷은 ZIP/7z의 허용 값만 받는다. SevenZipEdit는 기존 index를 유지/이름 변경하거나 결과 계획에서 제외해 삭제하고, 읽기 전용 추가 입력 FD와 합성 빈 폴더를 새 출력에 작성한다. 원본 경로를 열거나 원본 stream을 덮어쓰지 않는다.

새 출력은 비어 있는 단일 링크의 쓰기 전용 regular FD여야 한다. 잘못된 index·중복/NFC 충돌·절대/Windows drive/~ 경로·경로 이탈·파일 아래 하위 경로·원본/결과 크기를 사전 검사한다. source/input snapshot과 읽기 전용 FD를 검증하고, 유지 항목의 SDK test-mode CRC/암호 검사가 끝나기 전에는 출력하지 않는다. 기존 metadata/링크/설명은 원본 property/stream으로 유지하며 링크를 호스트에 풀지 않는다. SDK 후에도 원본·추가 입력과 출력 identity를 확인한다.

추가 입력 callback의 index는 유지 항목을 포함한 결과 배열의 index다. 호출자는 편집 시도 후 session을 닫아야 하며 오류 출력은 partial일 수 있다. **전체 출력의 독립 검증, 안전한 교체·백업·저널/Undo는 아직 구현하지 않았다.** 이 API의 성공만으로 원본을 교체해서는 안 된다.

ZIP decoder의 C 문자 변환에는 호출 스레드에만 UTF-8 locale을 적용하고 반환 시 복원한다. 프로세스 전체 locale을 변경하지 않는다. 7z의 기존 API 경로는 해당 ZIP 설정을 사용하지 않는다. CoreFoundation 경로 정규화 링크와 패키지의 재빌드 자료도 맞췄다.

## 검증

실제 새 번들에 대응하는 어댑터 소스 해시를 확인한 diagnostic-only probe에서 83개가 통과했다. 비암호 ZIP/7z, ASCII 암호 AES ZIP, Unicode/헤더 암호 7z의 파일·폴더 rename, 항목 삭제/전체 삭제, 파일/폴더 추가를 공식 7zz로 복원했다. 원본 bytes·유지 항목의 크기/암호화/권한/mtime, Unicode/개행 이름, opaque symlink 내용과 entry/archive comment를 확인했다.

원본/추가 입력 변경·writable/foreign FD·잘못된 source snapshot·read-only session 편집·format/index/경로/중복/크기·CRC 실패에서는 원본을 보존하고 검사 가능한 사전 실패는 빈 출력으로 거부했다. 모든 요청에서 호출 스레드의 locale 복원도 확인했다.

기존 실제 격리 helper 50개, 비격리 진단 SDK 142개, Swift 클라이언트 57개, 권한 probe 15개와 bundle fixture 8개도 통과했다. 제품 GUI·로컬 전체 AppKit·장시간 시험은 실행하지 않았다. 새 probe는 앱에 포함하지 않는다. 패키지 verifier에 추가해 후속 두 CPU CI에서도 대응 소스의 네이티브 API를 검사한다.

초기 시험에서 공식 ZIP writer가 비ASCII 암호 생성에 실패했고, reference 읽기에 -p를 붙여 stdin 암호를 사용하지 못한 setup도 수정했다. Unicode AES ZIP fixture는 독립 헤더/Apple AES primitive로 만들고 공식 7zz가 읽는 것을 확인했다. native ZIP 읽기의 locale 문제도 발견·수정했다. 초기 실패 로그를 보존하며 통과로 덮지 않는다.

## 명확히 남은 기능

기존 Unicode 암호 AES ZIP의 metadata 편집/내용 보존은 통과했지만 **새 암호 payload 추가는 현재 SDK writer가 거부한다**. native API는 이 경우 원본을 보존하고 출력 전에 unsupported를 반환한다. 기존 제품의 Unicode AES ZIP 기능을 축소하지 않도록 Core AES writer 등을 이용한 추가 경로를 구현해야 한다. 이 제한을 최종 지원 범위로 확정하거나 암호를 ASCII로 제한하지 않는다.

bounded 편집 IPC·Swift 편집 서비스, 전체 출력 검증과 안전한 교체/복구/Undo, 위 Unicode ZIP 추가 경로와 UI가 미완료다. update capability는 계속 false다. [전체 구현 계획](../../ARCHIVE_EDITING_PLAN.md)의 첫 단위도 아직 진행 중이다. 최대 규모·solid/mixed crypto/빈 암호 archive 정책·OS/볼륨·단계별 취소/재시작 수용도 남아 있다.

[새 API·기존 회귀·소스·패키지 증거](native-edit-370-verification.json).

## 기존 제품의 전체 UI 기준선

4a6c79d 실행 45847539460은 양 CPU 작업 전체 성공으로 완료됐다. ARM/Intel × 한국어/영어 × 밝게/어둡게의 여덟 프로필에서 각각 전체 332개·탭 경계 18개가 모두 통과했다. [실제 보고서 해시와 집계](remote-367-ui-receipt-370.json)를 보존했다. 이 기준선은 새 편집 API를 포함하지 않으며 물리 입력·VoiceOver나 원본의 모든 UI 상태 대조를 증명하지 않는다.

F23 전체와 정식 출시는 미완료다. 인증서/프로필은 사용자 준비 중이다.
