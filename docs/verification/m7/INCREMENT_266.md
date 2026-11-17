# M7 Increment 266 — 최신 소스의 유니버설 프리뷰 후보

소스 `958921f46eb6332a70f5b081fcd6e0741f99f0f6`에서 시험용 설치 이미지를 빌드했다. macOS 14.0 대상 arm64·x86_64 실행 파일, 각 슬라이스의 ad-hoc 서명, 배포 내용물 및 DMG 체크섬을 확인했다. 이미지 SHA-256은 `b70b61c2ef9df12599a394c1e526010ba50f738177e6720444372ed287dc3c04`이다. 완료 기록 지우기와 SMB 접근 시각 변경을 포함한다.

Apple Silicon macOS 27.2에서 이전 앱 설치, 손상된 교체본 거부, 새 앱 설치와 이전 앱 복원이 통과했다. 설정과 사용자 파일을 보존했고 두 세션 형식에서 창 상태를 복원했다. Launch Services로 20회 실행해 공유 캐시에서 메뉴 응답 p95 680 ms, 최대 986 ms를 기록했다. [설치·복원](preview-install-958921f.json) · [20회 기동](preview-launch-services-958921f.json)

GitHub 호스팅 macOS 14 러너는 2026-11-02에 종료됐다. Apple Silicon에서 실행할 Sonoma 가상 머신 이미지 준비를 시작했다. 최소 지원 OS에서의 설치·기동 여부와 SMB 접근 시각 실마운트 결과를 확인한다. [GitHub 러너 종료 공지](https://github.com/actions/runner-images/issues/13518) · [Tart의 Sonoma 시험 이미지](https://tart.run/quick-start/#vm-images)
