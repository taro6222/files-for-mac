# M7 Increment 336 — 새 유니버설 프리뷰와 Windows 압축 상태 수용

상태: 프리뷰 생성·ARM 격리 설치·Windows 입력/취소 수집 통과. Launch Services 20회 기동도 통과했으며 M7 정식 출시는 미완료다.

## 유니버설 개발 프리뷰

앱 소스를 a07c80c63356097bae3f00790d5147f29956c3b6으로 고정하고 git archive로 별도 폴더에 내보냈다. 소스 아카이브·실행 파일·이미지 해시를 기록한다. 기존 build/Files-macOS-preview.dmg는 40ffc39 프리뷰 해시 그대로 보존했다.

- 이미지: build/preview-a07c80c/Files-macOS-preview.dmg
- 체크섬: build/preview-a07c80c/Files-macOS-preview.dmg.sha256
- SHA-256: 2e8fd69f6d98021e058147080331bfabfb9b84ad51402bd5ea7b67894a77509f
- arm64·x86_64 슬라이스, 양쪽 서명, 번들·라이선스·릴리스 노트 및 DMG 구조·이미지 체크섬 검증 통과.
- ad-hoc 서명의 개발 프리뷰다. Developer ID 서명·공증은 적용되지 않았다.

두 슬라이스의 Mach-O는 minos 14.0과 sdk 14.0을 기록했다. SwiftPM이 생성한 값을 변경하지 않았다. 이 메타데이터로 해당 OS 실실행을 검증했다고 주장하지 않는다. 현재 Mac의 CLT로 빌드했으며 실제 설치 실행은 아래 arm64 macOS 27.2.1에 한정한다.

## 설치·교체·복원

macOS 27.2.1(26B131) arm64에서 별도 앱 식별자·홈·설정·fixture를 사용했다. 이전 프리뷰 설치, 손상된 staging 서명 거부 후 기존 앱 기동, 새 앱 교체, 이전 앱 복원을 통과했다. 네 단계에서 시작 경로·최근 세션 계속·즐겨찾기·확장자 표시 설정과 사용자 fixture를 보존했다. tabSession과 workspaceSessionV2의 실제 앱 복원을 확인했다.

창 표시 시간은 최초 설치 0.546초, 손상본 거부 뒤 0.157초, 새 후보 교체 뒤 0.563초, 복원 뒤 0.191초였다. 소규모 설치 기능 검증의 값이며 콜드 캐시 성능이나 키보드·마우스·VoiceOver 수용으로 집계하지 않는다. [프리뷰·설치 보고서와 해시](preview-a07c80c-verification.json).

Launch Services로 새 프로세스를 20회 기동한 첫 창 표시 p95는 278ms, 최대 985ms였다. 공유 OS 캐시를 사용했고 캐시를 지우지 않았다. 창 표시까지의 측정이며 콜드 시작 또는 실제 입력→피드백 성능으로 대체하지 않는다. 원본 표본은 프리뷰 검증 JSON에 보존한다.

## Windows UI-13 입력·취소

[실제 수집 실행](https://github.com/taro6222/files-for-mac/actions/runs/45756562666)은 성공했다. 원본은 Files v4.2.9의 99951c66928c4da714da8b1dd46039421182cbab, 수집 코드는 55c1bee다. 다섯 PNG와 접근성 트리, 실제 입력값 확인, 버튼 상태와 fixture manifest를 함께 검토했다.

| 상태 | 확인 |
|---|---|
| 정상 | preview.txt 기본 이름·포맷/압축 수준·활성 Create/Cancel |
| 빈 이름 | 이름이 비고 Create 비활성 |
| 잘못된 이름 | invalid/name 입력·오류 팝업 표시·Create 비활성 |
| 유효한 이름 | ReferenceArchive 입력·Create 활성 |
| 취소 | 압축 창 종료·원래 폴더 복귀·원본 manifest 보존 |

전후 manifest는 파일 4개·디렉터리 2개·96바이트와 동일한 해시였다. Create는 확정하지 않았으므로 실제 압축 파일 생성·추출·암호·분할 압축 성공을 의미하지 않는다. [원본 결과·PNG·트리 해시](windows-archive-336-acceptance.json).

PNG는 1920×1032px의 영어·밝은 테마다. DPI 배율이 수집되지 않아 scale-unrecorded로 이름을 붙였다. Mac과 같은 크기·배율의 픽셀 일치를 주장하지 않는다. Windows는 이름과 포맷을 별도 필드로 제공하며 Mac은 현재 NSSavePanel로 저장 이름·확장자를 정한다. Mac의 대응 입력 상태와 포맷별 옵션 차이, 전체 UI-13 시각·동작 수용은 계속 남아 있다.

최신 두 CPU 전체 AppKit, Intel 초기 Git 지연의 원인·해결, 원격 진단 파일 보존, 8시간 안정성·최소 OS와 Intel 설치, 실제 입력/VoiceOver·외부 서비스·정식 서명/공증은 미완료다. 인증서·notarytool 프로필은 사용자 준비 중이며 Mac 화면 잠금 해제 응답을 기다린다.
