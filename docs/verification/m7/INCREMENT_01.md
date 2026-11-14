# M7 Increment 01 — 로컬 프리뷰 DMG

## 로컬 빌드와 설치 확인

```sh
./scripts/build-dmg.sh --preview
(cd build && shasum -a 256 -c Files-macOS-preview.dmg.sha256)
```

- 2026-11-14 Apple Silicon macOS 27.2 (26B123), Swift 6.4.2 Command Line Tools에서 기능 소스 `4e57c3937ca2c91bb81a9946b1e182c8a5412beb`로 빌드했다.
- DMG는 `0.1.0`의 arm64 앱과 Applications 링크를 포함한다. Info.plist 배포 대상은 macOS 14.0이다.
- 파일 SHA-256 `8de6ff21bd2879f5a668ff4184f4dce9215b3d0eb2f82666c1ea0bba8d834c49`, `hdiutil verify`, 읽기 전용 마운트, 앱 `codesign --verify --strict`를 통과했다.
- 마운트된 앱 실행 파일이 로그인된 GUI 세션에서 4초 동안 유지되는 것을 확인했다. 이 시험의 서명은 ad-hoc이다.

## 정식 출시 검증 대기

```sh
FILES_SIGNING_IDENTITY='Developer ID Application: 발급 이름 (팀 ID)' \
FILES_NOTARY_PROFILE='이미 등록된 Keychain 프로필 이름' \
./scripts/build-dmg.sh --release
```

정식 경로는 Developer ID·hardened runtime 서명, macOS 공증, DMG staple 및 Gatekeeper 평가를 사용한다. 자격 증명은 Keychain 프로필을 사용한다. 이 호스트에서 유효한 서명 identity가 조회되지 않았으며 사용자는 인증서·공증 프로필을 준비 중이라고 확인했다. [Apple 공증 절차](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

마운트 실행 확인과 별도로 깨끗한 Mac에서 내려받은 설치 이미지·업데이트·복구 검증, Intel·최소 macOS, 실제 SMB 및 M5 외부 서비스, Windows 원본 UI 비교·VoiceOver·장시간 검증이 남아 있다.
