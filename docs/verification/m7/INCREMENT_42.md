# M7 Increment 42 — Launch Services 시작 검증

```sh
python3 scripts/verify-preview-install.py --interactive-startup --launch-services build/Files-macOS-preview.dmg
```

Apple Silicon macOS 27.2 (26B123)에서 `cb1dd9dd612ef6e9576db27a1ee8de50b764b334`의 유니버설 DMG를 사용했다. 이미지 체크섬과 양쪽 아키텍처의 앱 서명을 확인하고, 별도 설정 도메인에 설치한 복사본을 ad-hoc 재서명했다. Launch Services로 매회 새 프로세스를 열고, 해당 프로세스의 시작 폴더 창을 확인한 뒤 정보 메뉴를 macOS 접근성 액션으로 실행했다.

20회 요청부터 정보 패널이 등록되기까지 p95는 **540 ms**, 최댓값은 **844 ms**였다. OS 캐시를 공유했고 도구 실행 및 폴링 시간도 포함했다. 콜드 OS 캐시, 공증된 이미지 다운로드와 Gatekeeper, VoiceOver 음성 안내는 출시 검증에 남아 있다. [측정 표본](preview-launch-services-cb1dd9d.json)

별도 실험에서 복원된 분할 창을 WindowServer 목록에서 확인했다. 이 실행 세션의 외부 접근성 조회는 앱 메뉴를 반환했으나 보조 패널의 컨트롤을 확인할 수 있는 창 계층을 반환하지 않았다. 보조 패널 접근성 검증은 [AppKit 검사](INCREMENT_41.md) 범위로 유지한다.
