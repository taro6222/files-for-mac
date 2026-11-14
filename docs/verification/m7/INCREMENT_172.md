# M7 Increment 172 — macOS CI

GitHub Actions에서 main 푸시와 main 대상 PR, 수동 실행에 macOS 15의 arm64·x86_64 잡을 실행하도록 구성했다. 두 잡 모두 실제 아키텍처를 대조하고 Xcode 26.3에서 원본 인벤토리, Swift 테스트, APFS·대소문자 구분 APFS·exFAT·FAT32·HFS+ 마운트 시험을 실행한다. [GitHub 러너 목록](https://github.com/actions/runner-images/blob/main/README.md)

볼륨 스크립트는 선택한 Xcode의 Swift Testing을 사용한다. 별도 Command Line Tools 환경에서 해당 매크로 라이브러리가 설치된 경우 그 경로를 전달한다.

이 워크플로의 범위는 빌드·Swift 동작·로컬 임시 볼륨이다. macOS 14 실행, 서명·공증된 DMG, AppKit 수동 검증과 VoiceOver, SMB·외부 서비스는 출시 검증 현황에서 추적한다.

[첫 CI 실행](https://github.com/taro6222/files-for-mac/actions/runs/43632028805)에서는 두 아키텍처 모두 Swift 6.2.4가 복사·이동·복원 결과 상세 문구의 타입을 제한 시간 안에 검사하지 못했다. 결과 문구를 항목별로 조합하도록 바꾸고 로컬 FilesMac 빌드를 확인했다.

수정된 앱의 AppKit 회귀는 한국어·영어와 밝은·어두운 테마 네 조합에서 각각 269개 통과했다. 같은 FilesCore·테스트 소스의 로컬 Swift Testing 실행 결과는 230개 통과, 통합 fixture 부재로 11개 건너뜀이었다.

[두 번째 CI 실행](https://github.com/taro6222/files-for-mac/actions/runs/43632346070)에서 빌드와 테스트가 한 단계로 실행되어 대기 위치를 구분하기 어려웠다. 파이프라인에서 빌드·테스트·마운트 단계의 제한 시간을 각각 지정했다. 압축 취소 시험도 압축 및 해제의 첫 진행을 최대 10초 기다린 뒤, 진행이 없으면 시험 실패를 기록한다.

중복된 두 번째 실행을 종료하고 로그를 확보했다. 두 러너에서 Swift 6.2.4가 수정된 소스를 컴파일했으며 마지막 로그는 테스트 바이너리 링크였다. CI 빌드는 디버그 심볼 생성을 생략하고, 마운트 시험은 같은 테스트 바이너리를 재사용한다.

[디버그 심볼을 생략한 실행](https://github.com/taro6222/files-for-mac/actions/runs/43633336850)에서 양쪽 빌드를 통과했다. Apple Silicon에서 병렬 Swift 테스트가 5분 제한 시간을 넘겼다. CI 기본 회귀를 순차 실행으로 전환했다. 개별 테스트 내부의 동시 실행 검증은 그대로 실행한다.
