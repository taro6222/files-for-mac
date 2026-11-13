# 플랫폼 차이 및 결정 기록

| 항목 | 현재 결정 | 검증 상태 |
|---|---|---|
| UI | AppKit 네이티브 창·NSTableView. 시스템 언어에 따른 한국어/영어 표시 | arm64 실제 창에서 확인 |
| Windows 재질·창 제어 | macOS sidebar material·traffic lights | 원본 Windows 이미지와의 시각 비교 대기 |
| 명령 키 | ⌘L, ⌘[, ⌘], ⌘↑, ⌘↓, ⇧⌘. | 전체 키보드/VoiceOver 흐름 대기 |
| 항목 ID | 경로 기반 directory-entry ID + device/inode/birth 보조 identity | hard link 구분 및 유일한 identity의 외부 rename 선택 복원 통과 |
| 파일 종류 | 기본 메타데이터와 localizedTypeDescription을 분리; 현재 종류는 폴더/확장자 표시 | 부가 API 실패가 폴더 판별을 훼손하지 않도록 수정 |
| 변경 감시 | FSEvents 현재 폴더·직접 자식 관찰 | 로컬 파일 편집·rename 통과; 네트워크 볼륨은 검증 대기 |
| 패키징 | SwiftPM 코어/실행 + 같은 소스를 쓰는 Xcode 앱 타깃 | 정식 배포 전 코어를 별도 패키지 참조로 연결 정리 |
| 휴지통 전체 복원 | 미확정 | 공개 API 실험 대기 |
| 클라우드 상태·명령 | CloudStorage/iCloud 위치를 로컬 탐색; ubiquitous resource value가 있는 항목만 상태 표시하고 공개 FileManager API로 지금 다운로드·공간 비우기 제공. 일반 File Provider 상태는 unknown, 영구 오프라인 유지 명령은 미노출 | fixture 위치·unknown·비지원 명령 무변경·UI 4조합 통과; 실제 공급자별 수용 검증 대기 |
| 원격 연결 | FTP/FTPS/SFTP는 직접 provider, SMB는 macOS 마운트 경로 사용. 프로필은 mode 0600 JSON, 비밀은 Keychain generic password로 분리; FTPS 인증서와 SFTP host key 검증 필수 | 프로필 정규화·위험/손상 입력 거부·저장 권한·capability와 Keychain 어댑터 빌드 통과; 실제 Keychain 로그인·연결·전송은 검증 대기 |
| 압축 backend | macOS 시스템 libarchive 직접 연결; ZIP/7z 생성·탐색·안전 추출, RAR 탐색·안전 추출; 암호·분할·수정은 미지원 | ZIP/7z Unicode 생성·재열기·추출, 공식 7z/RAR fixture, 앱 UI 4조합 통과 |
| Intel/최소 OS | 배포 타깃만 설정 | 실기기 실행 대기 |
