# 388 — macOS 압축 저장 아카이브의 편집과 복구

## 해결한 문제

기존 편집 서비스는 UF_COMPRESSED 파일을 일괄 거부했다. 일반 metadata 복사만으로 이전 decmpfs 데이터를 새 아카이브 바이트에 붙이면 안 되므로, 검증된 새 논리 바이트로 파일 시스템 압축 저장 데이터를 다시 만드는 FD 기반 경로를 추가했다. 원본에는 쓰지 않는다. 데이터 형식이 ZIP/7z인 것과 파일 시스템이 파일 자체를 압축 저장하는 것은 별개다.

[Apple copyfile](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.c)의 metadata/data 처리 구분, [xnu 헤더](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/decmpfs.h)와 [libarchive 형식 설명](https://github.com/libarchive/libarchive/blob/master/libarchive/archive_write_disk_posix.c)을 확인했다. 코덱은 macOS 제공 zlib에 연결하고 파일 포맷 쓰기는 별도 Swift 코드로 구현했다. 원본 SDK 압축 helper나 그 권한은 변경하지 않았다.

## 제품 경로

새 `ArchiveEditCompression`은 열린 출력 FD의 논리 데이터를 64KiB 블록으로 처리한다. 작은 결과는 인라인 type 3, 나머지는 블록 테이블/리소스 포크의 type 4를 생성한다. 압축 효과가 없는 블록은 비압축 표식을 사용한다. 내용 기록과 확인 뒤 압축 flag를 설정하고 실제 OS 읽기의 전체 SHA-256/크기/identity가 이전 논리 데이터와 같은지 확인한다. 형식을 직접 해석해 성공을 추정하지 않는다.

압축 저장 생성은 원본의 읽기 전용 권한/ACL을 복사하기 전에 끝낸다. 이후 일반 metadata·birth time·새 수정 시간을 적용하고 내용과 속성을 다시 확인한 뒤 기존 게시 경로를 사용한다. source와 candidate 각각의 물리 compression header/리소스 포크 해시도 저널 metadata에 남겨 복구 시 각 파일의 저장 상태를 확인한다. 이전 원본은 이전 저장 표현을 그대로 보존하고 Undo/Redo에서 교환한다. 기존 압축 codec을 새 파일에도 그대로 사용한다고 주장하지 않으며 압축 flag와 논리 바이트를 유지한다.

새 CZlib 시스템 모듈을 SwiftPM과 Xcode 프로젝트 생성기에 연결했다. 프로젝트를 재생성했고 Debug/시험·두 CPU Release 빌드가 통과했다. Xcode 라이선스 승인이나 로컬 Xcode 실행은 하지 않았다.

## 실제 검증

실제 OS가 읽는 빈 파일·인라인·여러 블록·비압축성 데이터의 내용/크기/flag를 확인했다. 열린 FD와 새로 연 FD의 내용 및 물리 metadata 해시가 일치했다. 취소 때 기존 논리 내용이 읽히고 flag가 적용되지 않으며 기존 다른 리소스 포크는 덮지 않는 조건도 확인했다.

ZIP/7z 실제 편집에서 type 3→4와 4→3 전환, 0440 권한·일반 xattr 보존, 새 항목 목록과 데이터 복원, Undo/Redo의 원본 바이트와 각 물리 저장 snapshot 복원이 통과했다. ZIP은 제품과 같은 ZIP 목록/추출 경로를 사용한다. 초기 시험의 ZIP 생성/읽기 백엔드 선택과 폴더 trailing slash 비교를 수정했고 최종 전체 회귀를 다시 실행했다.

최종 실제 번들의 Swift 80개/격리 helper 113개/진단 205개/native 85개/권한 15개가 통과했다. 유니버설 DMG 내용물·서명·macOS 14.0 배포 메타데이터와 내부 체크섬/외부 SHA-256을 확인했다. [소스 전체 해시와 산출물](archive-compression-388.json). 앱 소스는 b6a999e에 이번 변경을 더한 작업 트리이며 빌드 당시 코드 해시를 기록했다.

## 프리뷰와 한계

`build/preview-388/Files-macOS-preview.dmg`는 이번 지원과 387의 명시적 휴지통 정리를 함께 포함한 ad-hoc 개발 프리뷰다. 이전 DMG를 덮어쓰지 않았다. 로컬 GUI·설치/기동·전체 AppKit·장시간 앱은 실행하지 않았다.

실제 저장 형식 수용은 type 3/4와 위 크기의 로컬 fixture 범위다. 다른 인식 형식 1/7/8/9/10/11/12, 큰 파일·남은 공간·전원 중단·지원 OS/볼륨의 전체 수용은 남아 있다. 알려지지 않은 형식, 인라인 방식의 별도 숨은 리소스 포크 등 모호한 저장 상태는 원본을 보존하고 거부한다. 파일 논리 크기는 기존 8GB 한도이며 생성 리소스 포크의 위치는 UInt32 범위 안이어야 한다. 한도를 넘거나 취소/검증이 실패하면 기존 복구 기록과 출력을 보존한다. 모든 동시 후보 metadata 변경 경계를 수용했다고 주장하지 않는다.

F23의 다른 게시 방식과 전체 오류/지원 환경/실제 UI 수용, 원본 기능·UI 전체 동등성 및 M7 서명/공증·지원 OS/CPU·실제 입력·VoiceOver·장시간 수용은 미완료다. 375개 UI 정의는 변경하지 않았다. 앞선 GUI 실행은 그대로 유지하며 이번 소스의 기본 push 검증으로 양 CPU 빌드/SDK와 설치 검증을 요청한다.
