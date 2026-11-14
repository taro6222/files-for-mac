# M7 Increment 21 — 다운로드한 정식 DMG 검증

정식 후보 DMG와 체크섬을 다운로드한 Mac에서, 해당 이미지 빌드에 사용한 소스 커밋을 체크아웃한 뒤 다음 검사를 실행한다.

```sh
bash scripts/verify-release-dmg.sh ~/Downloads/Files-macOS.dmg
```

같은 위치의 `Files-macOS.dmg.sha256`에 기록한 해시를 대조하고, 이미지 무결성·코드 서명·공증 티켓·Gatekeeper 결과를 확인한다. 읽기 전용 마운트에서 [DMG 내용물과 앱 서명](INCREMENT_55.md)을 검사한 뒤 macOS 배포 정책 검사를 실행한다. 그 후 깨끗한 Mac의 Finder에서 앱을 Applications 폴더로 복사하고 처음 실행한 결과를 기록한다. [Apple 공증 및 배포 안내](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

이 Mac에서 셸 구문 검사, 프리뷰 이름 거부, 외부 경로가 들어간 체크섬 목록 거부, 체크섬 불일치 거부를 확인했다. 정식 이름을 붙인 프리뷰 복사본은 올바른 해시와 이미지 무결성을 통과한 뒤 서명 검사에서 거부됐다. 정상 서명·공증된 다운로드의 통과 및 Finder 최초 실행은 자격 증명 준비 후 검증한다.
