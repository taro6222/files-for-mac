# M7 Increment 21 — 다운로드한 정식 DMG 검증

정식 후보 DMG와 체크섬을 다운로드한 Mac에서, 해당 이미지 빌드에 사용한 소스 커밋을 체크아웃한 뒤 다음 검사를 실행한다.

```sh
bash scripts/verify-release-dmg.sh ~/Downloads/Files-macOS.dmg
```

배포자가 별도로 확인해 준 Team ID가 있으면 두 번째 인자로 전달한다. 이 경우 DMG와 앱의 서명을 모두 해당 팀에 대조한다. 인자를 생략하면 앱과 DMG의 서명 팀 일치를 검사한다.

같은 위치의 `Files-macOS.dmg.sha256`에 기록한 해시를 대조하고, 이미지 무결성·코드 서명·공증 티켓·Gatekeeper 결과를 확인한다. 읽기 전용 마운트에서 [DMG 내용물과 앱 서명](INCREMENT_55.md)을 검사한 뒤 macOS 배포 정책 검사를 실행한다. 그 후 깨끗한 Mac의 Finder에서 앱을 Applications 폴더로 복사하고 처음 실행한 결과를 기록한다. [Apple 공증 및 배포 안내](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

이 Mac에서 셸 구문 검사, 프리뷰 이름 거부, 외부 경로가 들어간 체크섬 목록 거부, 체크섬 불일치 거부를 확인했다. 정식 이름을 붙인 프리뷰 복사본은 올바른 해시와 이미지 무결성을 통과한 뒤 서명 검사에서 거부됐다. 정상 서명·공증된 다운로드의 통과 및 Finder 최초 실행은 자격 증명 준비 후 검증한다.

정식 검증은 DMG와 내부 앱의 모든 아키텍처에 Developer ID Application 인증서를 요구한다. 앱의 Team ID를 읽어 앱과 DMG 서명 인증서의 조직 단위가 같은 값을 갖는지도 확인한다. 정상 체크섬을 가진 ad-hoc 서명 DMG는 Developer ID 검사에서 거부됐다. 별도로 설치된 Developer ID 서명 앱에서 같은 팀 조건은 통과했고 다른 팀 조건은 거부됐다. 프로젝트 인증서와 공증 프로필로 생성한 정식 이미지의 통합 검증은 남아 있다. [Apple 코드 서명 요구사항](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)

Team ID 옵션 추가 후 빈 값, 소문자, 잘못된 길이, 특수문자를 거부했다. 옵션 사용 여부와 관계없이 체크섬이 올바른 ad-hoc DMG는 Developer ID 단계에서 거부됐다.
