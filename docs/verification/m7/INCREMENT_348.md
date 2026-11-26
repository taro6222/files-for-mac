# M7 Increment 348 — SDK 포함 패키지와 진단 EOF 수정

상태: SDK 포함 ad-hoc 패키징·읽기 전용 이미지 실행 검증 완료. 앱의 SDK 선택/UI·최신 두 CPU Swift 재수용·지원 환경·정식 출시는 미완료다.

## 패키지

앱과 같은 CPU 구성의 Helpers/SevenZipWorker와 Frameworks/7z.so를 포함한다. 고정 SDK 빌드에서 thin 결과를 얻고 유니버설에서는 lipo로 합친다. SDK 라이브러리 ID는 빌드 폴더 이름 대신 @rpath/7z.so로 정리한다. helper는 부모가 명시한 library 경로를 사용한다. SDK version 26.06을 Info.plist에 기록한다.

Resources/ThirdParty/7zip에는 원본 DOC의 License.txt·copying.txt·unRarLicense.txt·readme.txt를 바이트 그대로 복사한다. 고정 원본 소스 archive, helper adapter와 빌드 recipe/핀 정보, 해당 프로젝트 라이선스와 재빌드 자료도 포함한다. 전체 SDK 소스에 있는 파일별 BSD/public-domain 고지도 archive에 남는다. 앱을 수정하기 전에 이 자료를 쓰기 가능한 별도 위치로 복사하도록 안내한다. 패키징의 라이선스 자료 제공을 검증한 것이며 법률 검토나 정식 배포 수용 완료를 뜻하지 않는다.

manifest에는 원본 SHA-256·두 CPU 빌드 입력·helper 소스/recipe 해시와 실제 포함 파일의 해시를 기록한다. 검증기는 정해진 파일/디렉터리 집합·symlink·원본 pin·고지/대응 소스·CPU 일치·macOS 14.0 배포 메타데이터·시스템 의존성·코드 서명을 확인한다. JSON manifest는 1MiB로 제한한다. 파일 hash 목록만 바꿔 source/notice 변조를 정당화할 수 없도록 pin과 빌드 입력도 대조한다.

라이브러리 → helper → 앱 순서로 서명한다. 코드 서명 후에는 두 code hash만 manifest에서 갱신하며 다른 resource의 변조는 거부한다. Developer ID 경로도 같은 순서를 사용하고 mounted/copied/Finder-installed 앱의 두 private code object에 동일한 Developer ID requirement/Team ID를 요구하도록 확장했다. 실제 Developer ID·공증은 사용자 준비 중이며 이번에는 ad-hoc만 실행했다.

기존 앱·DMG를 덮어쓰지 않는다. FILES_APP_OUTPUT와 FILES_DMG_OUTPUT_DIR로 새 경로를 지정하며 DMG는 임시 app에서 만든다. 이미지와 checksum의 최종 게시도 exclusive link를 사용해 중간에 생긴 출력을 덮어쓰지 않는다. 두 파일의 게시를 단일 원자적 트랜잭션으로 표현하지 않는다. SDK bundle이 이미 있으면 다시 설치해 실행 경로를 바꾸는 대신 새 app 출력을 요구한다.

## 실제 EOF 회귀

직전 [5c340f1 CI](https://github.com/taro6222/files-for-mac/actions/runs/45777580117)의 ARM Swift 게이트에서 암호 7z 왕복 함수가 invalidResponse로 실패했다. 실제 보고서를 내려받아 확인했다. 코드에는 stderr의 POLLIN을 읽지 않고 진단 데이터로 취급하는 경로가 있었다.

닫힌 파이프의 로컬 실제 probe는 revents 17(POLLIN|POLLHUP)과 0바이트 read를 반환했다. stderr를 먼저 닫고 정상 응답을 보내는 새 재현 검사는 수정 전 .invalidResponse로 실패했다. 이 경로를 실제 바이트를 읽어 구별하고 EOF 후 해당 진단 FD의 poll을 끝내도록 수정했다. 정상 종료 뒤 EOF 확인에서도 EINTR를 재시도한다. 실제 진단 바이트·추가 출력 거부와 기존 응답/크기 제한은 유지했다. 수정 후 재현을 포함한 Swift 9개가 모두 통과했다. 원격의 원래 실패 위치를 직접 추적한 것은 아니므로 이 수정의 최신 두 CPU 재수용은 다음 CI 결과로 확인한다.

## 검증

새 유니버설 app의 두 CPU 빌드·배포 메타데이터·시스템 링크·서명이 통과했다. 첫 패키징에서는 macOS 기본 Bash의 set -u/빈 배열 처리가 서명 단계를 중단해 고쳤고, 이미 빌드된 코드의 서명부터 재개했다. 번들 verifier의 manifest 복사 경로도 고쳤다. 이후 전체 app/DMG 스크립트를 새 경로에서 실행했다. EOF 제품 코드 수정 후에는 다시 별도 최종 경로에 빌드해 이전 후보와 섞지 않았다.

최종 이미지:

- 경로: build/sevenzip-348-final-preview/Files-macOS-preview.dmg
- SHA-256: 5b0d23164fc219d8b3c72ac64f72110eb0def633ac07123fb676fb53a2068b2f
- SDK 원본 archive SHA-256: a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4

DMG 생성 전 실제 app 안의 helper/library에서 ARM SDK 목록/추출 조건 59개와 Swift 클라이언트 9개가 통과했다. hdiutil checksum 검증 뒤 이미지를 읽기 전용으로 마운트해 내부 파일·원본 자료·서명을 검증하고 같은 59개/9개를 마운트 안의 code로 실행했다. 소스 이미지 identity와 hdiutil 소유 image/device/mount 관계를 확인해 첫 정상 detach 시도로 해제했다. force detach는 사용하지 않았다. 이는 앱의 실제 설치·교체·전체 UI 동선 수용은 아니다.

Core 전체는 참조/SDK를 활성화해 405개 중 성공 386개·환경 건너뜀 19개로 통과했다. bundle 보호 검사 8개와 기존 reference 보호 5개가 통과했다. bundle 보호에서는 실제 Mach-O 검사를 mock으로 분리하고, 실제 유니버설 app/DMG 검사에서 CPU/서명을 확인한다. Python 구문·shell 문법·workflow YAML·parity 구조 감사·diff 검사도 통과했다. [실제 결과·소스/구성 해시](archive-package-348-verification.json).

CI의 두 CPU에 bundle 보호 검사와 packaged SDK 실행/Swift 검증 artifact를 추가했다. 전체 AppKit 수동 실행은 DMG 생성 전의 실제 app에서 이 게이트를 필수 실행한다. 일반 app 빌드에도 SDK 구성/고지/서명 검증은 항상 적용한다. 새 필수 Swift 게이트는 9개 전체 실행을 요구한다. 확인 시점 직전 ARM 전체 작업은 위 Swift 게이트 실패, Intel은 진행 중이었다. 최신 원격 전체 성공으로 집계하지 않는다. 기존 331 8시간 시험도 같은 handle에서 실행 중임을 확인했으며 최종 안정성 판정은 아니다.

앱의 SDK resolver/실제 호출, 여기/스마트 배치·메타데이터 복원·7z 암호 생성/세부 옵션/분할·메모리/권한 격리·원본 UI/실제 입력/VoiceOver·지원 환경/최신 장시간 수용은 남아 있다. Spotlight EBUSY와 Intel 빌드/초기 Git 지연도 별도 미완료 항목이다. 정식 인증서·공증 프로필은 계속 준비 중이다.
