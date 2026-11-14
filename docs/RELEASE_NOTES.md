# Files macOS 0.1.0

Files for Mac은 Windows용 Files를 참고해 만든 독립 프로젝트입니다.

## 설치

1. 로컬 프리뷰는 `Files-macOS-preview.dmg`와 같은 폴더에서 `shasum -a 256 -c Files-macOS-preview.dmg.sha256`을 실행합니다. 정식 배포 이미지의 이름은 `Files-macOS.dmg`입니다.
2. DMG를 열고 `Files macOS.app`을 Applications 폴더에 복사합니다. 시스템 Applications에 쓸 권한이 없으면 사용자 홈의 Applications 폴더를 선택할 수 있습니다.
3. 복사한 앱을 실행합니다. 배포용 Developer ID 서명과 공증이 적용된 다운로드는 정식 출시 검증 후 제공할 수 있습니다.

## 사용 범위

- 탭·분할 보기·검색·미리보기·파일 속성, 로컬 파일 복사·이동·이름 변경·휴지통 및 실행 취소를 제공합니다.
- APFS·대소문자 구분 APFS·exFAT의 파일 작업과 시스템 휴지통을 확인했습니다. 실제 SMB 공유의 연결 중단·재연결과 권한 변경 검증은 남아 있습니다.
- FTP·FTPS·SFTP는 로컬 테스트 서버에서, 기본 Git 작업은 임시 Git 원격에서 검증했습니다. 외부 서버 인증과 실제 클라우드 계정은 검증 중입니다.
- 설치 이미지에는 Apple Silicon과 Intel 바이너리가 들어 있습니다. Apple Silicon macOS 27.2에서 기동했으며 Intel 실기기와 macOS 14 실행 검증은 남아 있습니다.
- Windows용 Files와는 시스템 메뉴, 압축 형식, 클라우드 및 파일 시스템 통합 범위가 다릅니다. 화면 대조와 VoiceOver 검증은 진행 중입니다.

## 복구

- 파일 작업이 중단되면 작업 결과와 출발지·대상 폴더의 내용을 확인한 뒤 필요한 항목을 재시도합니다. 휴지통으로 이동한 파일은 앱에서 복원을 시도할 수 있습니다.
- 테스트 버전을 교체하기 전에는 앱의 고급 설정에서 설정을 내보내고 기존 앱 번들을 보관합니다. 교체 후 문제가 발생하면 앱을 종료하고 보관한 번들을 복원한 뒤 필요한 경우 설정을 가져옵니다.

## 출처

- 앱 소스는 MIT 라이선스를 사용합니다. 이 이미지와 앱 번들에 `LICENSE.txt`가 포함됩니다.
- 비교 원본은 Windows용 Files v4.2.9입니다. 앱의 아이콘은 macOS 시스템 심볼을 사용하며 압축 기능은 macOS 제공 libarchive에 동적으로 연결합니다.
