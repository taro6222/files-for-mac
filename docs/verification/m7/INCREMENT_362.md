# M7 Increment 362 — 제품 7z helper App Sandbox 연결

상태: 패키징·실행 전 권한 검증·FD 동작과 로컬 arm64 headless 수용 완료. 최신 원격/지원 환경·다른 자원 경계와 M7 정식 출시는 미완료다.

## 제품 동작

helper에 __TEXT,__info_plist 식별자를 내장하고 com.apple.security.app-sandbox=true 하나만 부여한다. 부모 파일 관리 앱의 권한을 상속하거나 network/user-selected file 권한을 주지 않는다. SDK 라이브러리는 격리 CLI가 읽을 수 있는 Contents/Helpers/7z.so로 옮겼고 Frameworks는 빈 디렉터리로 검증한다. 코드·source pin·hash·CPU·서명 역할·Team 검사와 복사된 번들의 불변 identity 검증은 유지한다.

부모의 native factory는 서명 정보에서 정확한 단일 Boolean sandbox entitlement와 helper의 내장 ID·실행 파일명·background 플래그를 확인한다. 비격리·상속·네트워크·넓은 파일 권한으로 유효하게 재서명한 helper도 실행 전에 거부한다. 패키징 Python 검증은 모든 포함 CPU의 entitlement를 검사한다. stable 서명/공증 검사는 새 라이브러리 위치를 사용한다.

제품의 읽기·분할·생성은 기존 SCM_RIGHTS FD 공급을 그대로 쓴다. legacy 임의 원본 경로 열기는 제품 sandbox에서 거부한다. App Sandbox는 코드/시스템 읽기와 자체 컨테이너 등을 허용하므로 파일 시스템 접근이 전혀 없다고 주장하지 않는다. CPU·프로세스 트리 경계와 관찰 기반 메모리 예산은 별도 항목이다.

## 검증

- 최종 preview 번들의 실제 격리 helper/library를 사용한 Swift 연동 54개가 건너뜀 없이 13.999초에 통과했다. 기존 암호·여섯 수준·고급 옵션·분할·300개 생성 입력·metadata·취소·저널/재시작 복구와 번들 보호를 유지했다. 새 검사는 권한 확대/누락으로 유효하게 재서명한 helper를 native factory가 거부함을 확인했다.
- 같은 번들의 native FD 검사 25개가 통과했다. 임의 외부 원본 경로는 source-open으로 거부하면서, 삭제된 원본 FD 탐색/추출·적은 FD 한도의 분할 읽기·FD 생성과 독립 공식 7-Zip 복원·잘못된 권리/marker/identity를 검사했다.
- 개발 진단용 비격리 SDK의 전체 117개 검사도 유지했다. 기존 raw suite의 FD 부분을 공통 함수로 분리해 제품에도 실행하고 legacy 경로 방식은 진단 도구에서 별도로 검증한다. 117개를 제품 sandbox 검사로 집계하지 않는다.
- 제품의 정확한 단일 entitlement profile로 서명한 test-only native probe가 OS 권한 15개를 통과했다. 실제 recvmsg로 받은 읽기 FD와 검색 전용 directory FD를 사용했다. 직접/상대 외부 파일 읽기, 원본 chmod/수정 시각 변경, directory chmod, 외부 쓰기, loopback connect/bind는 EPERM이었다. 전달 FD 읽기/쓰기·private socket·bundle 내 SDK 로드와 원본/선택 외 파일·폴더 권한 보존은 성공했다. 이 probe는 제품에 포함하지 않으며 실제 제품 FD 검사는 위 25개/54개와 구분한다.
- fixture 보호 8개, Debug 18.67초·최종 시험 제품 7.76초, Release 31.46초·새 bundle 서명/해시 검증과 shell/YAML 검사가 통과했다. 로컬 GUI·전체 AppKit·장시간 시험은 실행하지 않았다.

[소스·결과·로그 해시](sandbox-362-verification.json)를 보존한다. 헤더 내장과 라이브러리 위치는 361단계의 초기화/SDK 로드 실패 증거를 따른다. 재빌드 자료에는 내장 정보·단일 권한·진단 도구와 제품 차이를 명시했다.

## CI와 남은 항목

push의 실제 preview 패키징에서도 SDK package 검증과 결과 artifact를 필수 실행하도록 연결했다. 따라서 두 CPU의 새 제품 sandbox 수용을 기본 push 경로에서 추적한다. 업그레이드 전용 실행이나 전체 AppKit 반복을 추가하지 않았다.

이전 bf3a91a의 ARM Debug 빌드는 같은 실행에서 약 670초 뒤 성공했다. 회수한 관리자 스택은 llbuild의 child spawn/poll 대기였고 private process group 관찰에는 컴파일러 자식이 포함되지 않았다. 이 증거로 이전 12분 시간 초과의 근본 원인을 확정하거나 전체 원격 검증 성공으로 표시하지 않는다. 자식 프로세스 관찰 범위를 보완해 실제 계산/대기 상태를 확인해야 한다.

최신 두 CPU/최소·최신 OS의 격리 수용, Developer ID·공증/설치, CPU/프로세스 트리와 실제 자원 수용, 나머지 metadata·큰 생성 계획, 실제 입력/VoiceOver·원본 UI 대조·외부 서비스 게이트는 남아 있다. 인증서/프로필은 사용자 준비 중이며 로컬 장시간 시험은 자동 재시작하지 않는다.
