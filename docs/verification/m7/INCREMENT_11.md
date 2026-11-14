# M7 Increment 11 — 프리뷰 앱 시작 시간

```sh
python3 scripts/verify-preview-install.py --startup build/Files-macOS-preview.dmg
```

2026-11-14 Apple Silicon macOS 27.2 (26B123)에서 프리뷰 DMG의 체크섬과 두 아키텍처의 서명을 확인했다. 이미지에서 앱을 복사하고 고유 설정 도메인과 임시 홈을 사용하도록 복사본을 ad-hoc 재서명했다. DMG 출처는 `0d8122ba10815ee418c7a8c3519fd57cf2622ca8`이다.

최적화된 앱을 QA 진입점 없이 20회 새 프로세스로 실행했다. 프로세스 실행 요청부터 WindowServer 목록에 빈 테스트 시작 폴더 제목의 AppKit 창이 나타날 때까지 측정했다. 매회 프로세스를 종료하고 OS 캐시는 공유했다. 첫 표본은 **596 ms**, p95는 **248 ms**, 최댓값은 **596 ms**였다. 같은 스크립트의 이전 프리뷰 설치·손상본 거부·정상 교체·복원도 다시 통과했다. [20회 측정 결과](preview-startup-local.json)

배포 성능 예산은 콜드 시작부터 실제 상호작용까지를 대상으로 한다. 이 시험에는 콜드 OS 캐시, Launch Services·Gatekeeper 및 입력 반응 시점이 포함되지 않아 해당 게이트는 진행 중으로 둔다.
