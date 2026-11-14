# M7 Increment 73 — 설치 이미지의 실행 환경 확인

프리뷰 시작 검증에 `--expect-architecture`와 `--expect-macos`를 추가했다. 첫 번째 옵션은 실행한 앱 프로세스의 아키텍처를 각 창에서 확인한다. 두 번째 옵션은 시작 전에 macOS 제품 버전을 정확히 대조한다. 빌드에 포함된 슬라이스의 검사와 별도로 실제 실행 환경을 보고서에 남길 수 있다.

Intel·macOS 14 검증 장비에서 사용할 예시다. 아래의 `14.8.3`은 실행하려는 장비의 정확한 버전으로 바꾼다.

```sh
python3 scripts/verify-preview-install.py --startup --run-parent /private/tmp \
  --expect-architecture x86_64 --expect-macos 14.8.3 build/Files-macOS-preview.dmg
```

Apple Silicon macOS 27.2에서 현재 프리뷰의 20회 창 표시와 arm64 실행을 확인했다. 공유 OS 캐시에서 창 표시 p95는 248 ms, 최대 591 ms였다. 잘못된 OS를 지정한 경우 시작 전에, x86_64를 지정한 경우 실제 arm64 프로세스를 확인한 뒤 거부했다. Intel 실기기와 최소 macOS에서 같은 검증을 실행해야 한다.
