# M7 Increment 187 — 갱신된 개발 프리뷰의 8시간 시험 시작

[최신 개발 프리뷰](PREVIEW_0.1.0.md)의 소스 `0a658381b460b83117ffb3692bfc0cedf7588172`와 시험 빌드 원본 `90303aa8eb8b61b7688e795f580e6ef142d8a2b1` 사이의 `Sources`와 `Package.swift`를 대조했다. 두 트리의 앱 빌드 입력이 일치한다. arm64 슬라이스의 플랫폼은 macOS이고 최소 배포 대상과 기록된 SDK가 모두 14.0으로 일치한다. [Mach-O 및 체크섬 결과](soak-build-metadata-0a65838-arm64.json)

Apple Silicon macOS 27.2에서 최적화 QA 빌드가 전체 부하를 시작했다. 120초에 실행 중인 프로세스와 탐색·탭 생성 및 닫기·복사·디렉터리 감시 43사이클을 확인했다. 장시간 메모리 안정성은 28,800초 결과로 판정한다.
