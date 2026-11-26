# 383 — 최신 유니버설 개발 프리뷰 DMG

최신 앱 코드 `7e31fc6`으로 **로컬 앱을 실행하지 않고** Apple Silicon/Intel을 포함한 개발 프리뷰를 만들었다. 릴리스 안내에는 ZIP/단일 7z 편집·암호 선택·Undo/Redo/기록 복구와 SDK 고지 위치를 반영했다. 이 안내의 hash도 산출물 기록에 묶었다.

| 산출물 | 값 |
|---|---|
| DMG | `build/preview-383/Files-macOS-preview.dmg` |
| 체크섬 파일 | `build/preview-383/Files-macOS-preview.dmg.sha256` |
| 크기 | 11,070,552 bytes |
| SHA-256 | `4a82e5646d3f5c4ef9e75ff61f938ba0081f2328854ec5b4d19872b2adf97ffb` |
| CPU / 최소 대상 | arm64 + x86_64 / macOS 14.0 |
| 서명 | ad-hoc 개발 프리뷰 |

최소 대상 메타데이터는 최소 OS의 실제 실행 수용을 뜻하지 않는다. Developer ID 서명·공증은 적용하지 않았으며 정식 출시가 아니다. SDK/바이너리/고지/릴리스 안내를 확인하고 `hdiutil verify`와 checksum 파일 대조를 통과했다. SDK 원본 소스 압축본·도우미 소스·변경 및 재빌드 recipe와 고지를 번들에 포함했다.

## 실제 번들·이미지 검증

macOS 27.2.1 arm64에서 새 유니버설 앱의 Swift 클라이언트 74개·격리 helper 113개·진단 SDK 205개·native 편집 85개·OS 권한 probe 15개를 통과했다. 이는 Apple Silicon에서 실행한 조건이며 Intel slice의 실제 실행을 대신하지 않는다.

DMG를 `/private/tmp/files-preview-383.*`에 읽기 전용·nobrowse로 마운트했다. 커널 `ST_RDONLY`와 `diskutil`의 `WritableVolume=false`를 확인하고 실제 이미지의 두 CPU 서명·배포 대상·내용물·릴리스 안내 일치를 검증했다. 이미지 안의 SDK/앱 자료를 참조한 Swift 클라이언트 74개도 통과했다. 정상 detach와 마운트 디렉터리 제거를 확인했으며 원본 이미지 SHA-256이 일치한다.

첫 마운트에서는 검증 코드가 이 OS에 없는 `VolumeReadOnly` 필드를 기대해 payload 검사 전 중단했다. 해당 시도도 정상 해제했다. 실제 OS 필드 `WritableVolume`과 커널 플래그로 수정해 새 마운트에서 검증했다. 첫 시도의 종료 기록도 보존했다. 관찰 제한 시간 때문에 작업을 재시작한 경우는 없다.

GUI 앱·설치 앱·로컬 장시간 시험은 실행하지 않았다. 이 검증을 Finder 설치·최초 GUI 실행·실제 VoiceOver 수용으로 집계하지 않는다. 최신 두 CPU [45882828053](https://github.com/taro6222/files-for-mac/actions/runs/45882828053)는 기존 실행을 유지하며 관찰 시 빌드/SDK 준비 중이었다. 다른 소스 62f8d40의 ARM 전체 성공은 [382 기록](INCREMENT_382.md)과 구분한다.

실제 인텔 수용과 간헐 UI 실패 원인·다른 파일 시스템/속성 경계·실제 입력/지원 환경·장시간·정식 서명/공증 등 F23/M7은 미완료다. 산출물은 build에 두고 앱·이미지·캐시·인증 자료를 Git에 포함하지 않는다. [산출물·소스·검증 기록](preview-383.json).
