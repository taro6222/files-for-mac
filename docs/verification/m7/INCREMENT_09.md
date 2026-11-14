# M7 Increment 09 — 설치 이미지 안내와 라이선스

`build-app.sh`는 서명 전에 앱의 `Contents/Resources/LICENSE.txt`를 넣는다. `build-dmg.sh`는 프리뷰와 정식 이미지의 최상위에 같은 라이선스와 릴리스 노트를 넣는다. 릴리스 노트는 0.1.0의 설치·복구 절차, 실제로 확인한 환경과 남은 검증을 안내한다.

앱에는 프로젝트 MIT 라이선스와 macOS 시스템 심볼이 적용된다. Windows용 Files v4.2.9는 고정 비교 기준이다. 앱이 사용하는 libarchive는 OS의 `/usr/lib/libarchive.2.dylib`에 연결되며, 출처가 기록된 7z·RAR 샘플은 테스트 타깃에만 들어간다. [비교 원본](https://github.com/files-community/Files/tree/v4.2.9) · [테스트 fixture 출처](../../../Tests/FilesCoreTests/Fixtures/README.md)

## 로컬 검증

2026-11-14 Apple Silicon macOS 27.2 (26B123)에서 프리뷰 DMG를 제작했다. 이미지 체크섬과 읽기 전용 마운트, Applications 링크, 라이선스 두 사본과 릴리스 노트의 원본 일치, 테스트 아카이브 제외, 버전 0.1.0, 두 아키텍처의 ad-hoc 서명을 확인했다. 마운트한 arm64 앱의 기동 확인도 통과했다. Swift Testing 201개와 두 빌드 스크립트의 구문 검사를 통과했다.

프리뷰 DMG SHA-256은 `f8e10956c8c776f110f58c353179fe1d224f1b070c4c858535c1b7bce4be85d7`이다. Developer ID 및 공증 프로필은 준비 중이며, 다운로드한 정식 버전의 Gatekeeper·교체·재설치 검증은 남아 있다.
