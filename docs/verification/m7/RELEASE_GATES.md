# M7 출시 검증 현황

| 검증 | 현재 증거 | 완료에 필요한 실행 |
|---|---|---|
| 로컬 설치 이미지 | [최신 유니버설 프리뷰](PREVIEW_0.1.0.md)의 Apple Silicon 마운트, 체크섬, 두 슬라이스의 ad-hoc 서명, 격리 설치·교체·복원 | 깨끗한 Mac에서 다운로드·설치·재실행 |
| Developer ID·공증 | 공증 응답 검사와 [다운로드 DMG의 빌드 SHA-256 대조](INCREMENT_143.md), [복사된 앱의 서명·배포 정책 확인](INCREMENT_144.md), 모의 실패에서 기존 산출물 보존 확인. 자격 증명 준비 중 | 설치된 인증서와 Keychain 프로필로 정식 DMG를 만들고 다운로드 후 검증 및 실행 |
| OS·CPU 환경 | Apple Silicon macOS 27.2에서 실행, DMG의 arm64·x86_64 최소 대상 macOS 14.0 및 서명 확인. [프리뷰 실제 arm64 실행 확인](preview-launch-services-509d293.json) | Intel 및 최소 지원 macOS 14에서 실행·회귀 |
| 로컬·네트워크 볼륨 | APFS·대소문자 구분 APFS·exFAT 파일 작업, 일괄 이름 교환, 교체 중 취소 및 [게시 직후 대상 교체 감지](INCREMENT_43.md), 시스템 휴지통 및 [APFS 간 메타데이터 보존](INCREMENT_117.md) 검증. [리소스 포크 변경 시 원본 보존](INCREMENT_118.md), [이전 폴더 이동 기록의 실행 취소](INCREMENT_119.md), [확장 속성 변경 시 원본 보존](INCREMENT_120.md), [ACL·권한 불일치 시 원본 보존](INCREMENT_121.md), [수정 시간 확인](INCREMENT_122.md), [속성별 전송 실패 안내](INCREMENT_123.md), [복사 실행 취소의 메타데이터 보호](INCREMENT_124.md), [이동 실행 취소의 메타데이터 보호](INCREMENT_125.md), [이동 다시 실행](INCREMENT_126.md), [APFS 일반 파일 생성 시간](INCREMENT_129.md), [APFS 폴더 생성 시간](INCREMENT_130.md), [exFAT 생성 시간 왕복](INCREMENT_131.md), [FAT32·HFS+ 생성 시간 왕복](INCREMENT_133.md), [APFS 전송 결과 접근 시간](INCREMENT_134.md), [exFAT 결과 접근 시간과 FAT32·HFS+ 제약](INCREMENT_135.md) 검증. 루프백 SMB 마운트와 [무응답 검증 종료](INCREMENT_36.md)와 [목록 조회 사전 검사](INCREMENT_141.md) 확인. [앱의 SMB 목록 검증 경로](INCREMENT_142.md) 추가 | SMB 생성 시간, 원본 접근 시간 및 FAT32·HFS+ 접근 시간 제약 확인, SMB 파일 작업·재연결·중단·권한·갱신 |
| 외부 서비스 | FTP/FTPS/SFTP 루프백 및 Git 임시 원격 검증. [실제 병합 충돌의 읽기·UI 표시](INCREMENT_108.md)와 [OpenSSH 키·에이전트 인증 및 인증 실패 복구](INCREMENT_109.md), [HTTPS와 macOS Keychain 인증](INCREMENT_110.md), [Git 동기화의 대상 ref와 비강제 푸시 검증](INCREMENT_113.md), [로컬 Git 훅 비활성화](INCREMENT_114.md), [특수 파일명 탐색·Git 상태](INCREMENT_116.md) | 실제 클라우드 계정, 외부 서버 인증·오프라인, 외부 Git 서비스 로그인·토큰 갱신 |
| 기능·화면 대응 | 인벤토리 378/378건 분류와 구조 감사 통과. [Swift 테스트 240개](INCREMENT_162.md), [검색 회귀 6회 반복 통과](INCREMENT_132.md), [AppKit 검사 조합별 268개와 폴더 소유권 적용](INCREMENT_162.md), [보조 패널 접근성](INCREMENT_111.md), [복사·이동 접근성 알림과 AppKit 파일 작업 검사 조합별 68개](INCREMENT_140.md), [UI-01~20 원본 소스·macOS 구조 대조](../../reference/UI_BASELINE.md) | 적용 기능의 항목별 수용 검증, UI-01~20 실행 화면과 상태 대조, 전체 키보드 동선 및 VoiceOver |
| 성능·장시간 | [10,000항목 전체 표시 p95 1.343초, 100,000항목 전체 최대 11.370초, 5분 유휴 후 1.277초](INCREMENT_163.md). 공유 OS 캐시와 동시 부하에서 [최신 프리뷰 Launch Services 시작→메뉴 응답 p95 617 ms](preview-launch-services-509d293.json). [시작 폴더 지연과 수정](INCREMENT_107.md) 확인. APFS 512 MiB 복사는 검증을 포함한 네이티브 기준 처리량의 102.95%. [같은 APFS 볼륨에서 512 MiB 이동 중앙값 218.9 ms, 실행 취소 218.7 ms](INCREMENT_128.md). [스크롤 AppKit 호출 p95 1.47–1.57 ms](INCREMENT_99.md). [5분 유휴 후 10,000항목 전체 표시 1.189–1.380초, 3회](INCREMENT_115.md) | 콜드 OS 캐시와 정식 배포 앱 시작부터 상호작용까지, 60Hz 화면 합성 프레임, 장시간 메모리·8시간 시험 |
| 업데이트·복구 | 최초 v1 설정 파일 가져오기와 다시 읽기, 미래 스키마 거부. 격리 프리뷰 설치·손상본 거부·교체·복원과 [설정·탭 세션 변환·사용자 파일 보존](PREVIEW_0.1.0.md) 통과. [손상된 분할 세션에서 시작 복구](INCREMENT_70.md), [정상 탭의 부분 복원](INCREMENT_71.md) 확인 | 정식 버전 간 설정 마이그레이션, 설치 실패 복구 및 배포 이미지 버전 확인 |
| 라이선스·릴리스 노트 | [DMG 내용물 자동 검증](INCREMENT_55.md)으로 앱·DMG 라이선스, 설치·복구 안내, 두 아키텍처의 OS 제공 libarchive 연결 및 테스트 fixture 제외 확인. [최신 내장 안내와 이미지 내용물](INCREMENT_112.md) 확인 | 서명·공증된 정식 다운로드 이미지에서 내용 재검사 |

[정식 출시 기준](../../VALIDATION_AND_RELEASE.md)은 이 표의 환경별 실행 결과가 갖춰진 뒤 판정한다.

[Samba 서버 대조](INCREMENT_96.md)에서 Linux 클라이언트의 파일 왕복은 통과했고, 같은 공유의 macOS 게스트·인증 마운트는 디렉터리 조회 단계에서 제한 시간을 초과했다.

상세 목록을 창에서 분리한 뒤 [125사이클 탐색 대조](INCREMENT_76.md)에서 셀 보유가 누적되지 않았다. 닫힌 창 정리를 적용한 별도 QA 바이너리에서 전체 8시간 부하 시험을 실행 중이다. 이전 프리뷰와 같은 앱 소스로 [45초 예비 시험](release-soak-7e5d11c-smoke.json)을 완료했고 [8시간 전체 부하 시험](INCREMENT_138.md)을 별도로 시작했다. [시험 결과 식별](INCREMENT_137.md) 직전 프리뷰 앱 소스의 [8시간 전체 부하 시험](INCREMENT_157.md)도 실행 중이다.

[장시간 시험 중간 힙 비교](INCREMENT_92.md)에서 상세 셀 수가 제한된 상태에서도 AppKit 관찰 객체와 물리 메모리 증가를 확인했다. [최근 위치 갱신 30분 대조](INCREMENT_93.md)에서는 두 빌드에서 비슷한 종료 표본을 기록했다.

[닫힌 창의 콘텐츠 해제](INCREMENT_95.md)를 적용한 뒤 독립 창 30분 시험의 종료 물리 메모리가 5,933.4 MiB에서 145.9 MiB로 줄었다. 탐색·탭·전송의 30분 시험도 완료했다. 8시간 검증과 독립 창의 잔여 증가분 확인이 남아 있다.

파일 작업의 동시 변경 검증에는 [교차 볼륨](INCREMENT_44.md)과 [같은 볼륨](INCREMENT_45.md)의 폴더 실행 취소 보호, [취소 시 변경된 백업 보존](INCREMENT_47.md)을 포함한다. 교체 이동의 실행 취소는 [테스트 프로세스 강제 종료 후 복원](INCREMENT_54.md)과 [중단 후 메타데이터 변경 보호](INCREMENT_145.md), [백업 복원 직전 중단과 재시작 충돌 보호](INCREMENT_146.md), [교차 볼륨 실행 취소의 비덮어쓰기 게시](INCREMENT_147.md), [같은 볼륨 이동·실행 취소 충돌 보호](INCREMENT_148.md)를 검사했다.

[백업 없는 교차 볼륨 이동의 실행 취소](INCREMENT_149.md)에서도 APFS 강제 종료 후 재개 및 복원본의 메타데이터 변경 보호를 확인했다.
