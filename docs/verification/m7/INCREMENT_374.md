# 374 — Unicode 암호 ZIP 새 파일 추가, F23 진행 중

ZIP 편집에서 한글·이모지 암호로 새 데이터를 암호화하지 못하던 제한을 해결했다. 검증·원본 교체·백업·Undo API에 연결해 실제 저장과 복원을 확인했다. 편집 화면과 다른 파일 시스템/압축 저장 metadata·Redo·빈 암호 archive 정책 등의 전체 수용은 남아 있으며 update는 아직 false다.

## SDK 변경과 출처

공식 26.06 소스 archive의 pin과 원본 bytes는 유지한다. 빌드 recipe가 hash를 확인한 private 추출본에 다음 두 변경만 적용한다.

- ZipHandlerOut.cpp: WinZip AES 암호를 명시적으로 UTF-8 바이트로 변환한다. AES에만 ASCII 제한을 적용하지 않으며 기존 ZipCrypto 검사/변환 경로는 유지한다.
- Crypto/WzAes.h: 99바이트의 구현상 암호 상한을 private 요청 ceiling인 1MiB로 조정한다. 전체 요청의 framing 상한도 계속 적용되므로 암호만 1MiB인 요청을 항상 허용한다는 뜻은 아니다. 다중 바이트 암호를 ASCII로 제한하거나 자르지 않는다.

cipher/KDF/인증·반복 횟수·salt 생성은 바꾸지 않는다. Native 어댑터에서 새 Unicode 암호 데이터를 일괄 거부하던 검사도 제거했다. 원본/편집본의 CRC·내용/속성 audit, 원본 변경·출력 identity, 암호화 유지·안전한 교체/복구 계약은 유지한다.

`SDKChanges`에 변경 식별자와 두 파일의 원본/변경 SHA-256을 기록하고 build fingerprint에 포함한다. 변경 전 hash·정확한 치환 위치·변경 후 hash가 맞지 않으면 build를 중단한다. Python 패키지 검사와 Swift runtime resolver도 기대한 변경 설명을 요구한다. 누락·다른 설명을 거부하는 fixture를 추가했다. 번들 BUILD.md에는 변경 내용과 `apply_sdk_changes`를 포함한 재빌드 recipe를 안내한다. 원본 SDK archive·기존 notices·해당 helper/recipe 전체 소스도 번들에 유지한다. 공식 SDK를 수정하지 않았다고 표시하지 않는다.

## 실제 검증

| 범위 | 결과 |
|---|---|
| Debug / Release | 14.31초 / 33.85초 빌드 통과 |
| Swift 클라이언트·번들 | 69개 통과 |
| 실제 격리 helper / 비격리 진단 | 113개 / 205개 통과 |
| native 편집 / OS 권한 probe | 85개 / 15개 통과 |
| 패키지 fixture | 9개 통과 |

한글·이모지 암호 ZIP의 새 파일 추가, metadata 변경, 모든 항목의 암호화 유지, 전체 편집본 검증·실제 저장·백업·Undo를 확인했다. 결과를 기존 Core ZIP 읽기 API로 추출하고 원래 내용을 비교했다. 독립 AES fixture와 일반 Unicode·NFC/NFD 암호의 추가 결과는 수정하지 않은 공식 7-Zip으로도 복원했다.

99바이트를 넘는 440바이트 암호와 개행/탭 암호도 기존 Core ZIP 읽기 경로 및 수정 SDK로 왕복했다. 이 두 경계는 공식 CLI 복원 검사와 구분한다. NFC 암호와 NFD 암호를 바꾸어 입력하면 틀린 암호로 거부했으며 암호 자체를 정규화하지 않는다. 원본과 백업의 bytes 보존 및 Undo도 확인했다. 새 암호 데이터는 UTF-8 바이트를 사용하며 암호를 argv·환경·설정에 넣지 않는다.

## 원격 보고서 업로드 실패 수정

이전 371 실행 [45860713694](https://github.com/taro6222/files-for-mac/actions/runs/45860713694)의 Intel 작업은 `Retain packaged SDK execution reports`에서 실패했다. 로그는 `edit-sdk/restored-7z-encrypted/new-folder/한글\nadded.txt`의 개행을 artifact 파일명으로 허용하지 않는다고 명시했다. ARM 작업은 cancelled였으며 그 이유를 추정해 통과로 처리하지 않는다.

기존 SDK 시험 파일을 제거하거나 이름을 바꾸지 않고 보고서 디렉터리 전체를 COPYFILE_DISABLE=1 tar.gz로 묶어 업로드한다. workflow YAML 구문을 확인했고 실제 새 보고서의 개행 이름 파일 4개를 tar member에서 읽어 원본 SHA-256과 일치함을 확인했다. 이 로컬 확인을 새 원격 업로드 성공이라고 표시하지 않는다. 기존 372/373 실행은 관찰 당시 queued/pending이었다.

[소스·SDK 변경·최종 보고서·업로드 수정 검증 기록](unicode-zip-374.json). 로컬 GUI·전체 AppKit·장시간 시험 앱은 실행하지 않았다. UI/최신 양 CPU·지원 환경과 정식 서명/공증 수용을 포함한 F23/M7은 계속 진행 중이며 인증서/공증 프로필은 사용자 준비 중이다.
