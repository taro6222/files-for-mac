# M7 Increment 288 — Xcode 프리뷰의 업데이트 채널 메타데이터

[첫 Xcode 검증 실행](https://github.com/taro6222/files-for-mac/actions/runs/45618079399)에서 macOS 15 Apple Silicon과 Intel의 네이티브 앱 빌드가 모두 `BUILD SUCCEEDED`로 끝났다. 이후 앱 번들의 `FilesReleaseChannel` 검사에서 키가 없어 실패했다. 사용자 지정 `INFOPLIST_KEY_` 빌드 설정이 생성 plist에 포함될 것으로 가정한 구성을 수정했다.

생성기는 명시적인 `FilesMac.xcodeproj/Info.plist`를 함께 만들고 Debug·Release 구성 모두 이 파일을 사용한다. 실행 파일·버전·번들 ID·최소 OS는 Xcode 빌드 설정을 참조하고 프리뷰 채널을 plist에 직접 기록한다. CI는 두 생성 파일이 저장소와 일치하는지도 검사한다.

두 구성의 plist 연결, 필수 메타데이터, 생성 결과의 반복 일치와 파일 구문 검사를 통과했다. 수정한 메타데이터를 포함한 실제 앱은 Xcode 전용 CI에서 다시 확인한다. 로컬의 실제 키보드 시험은 클립보드 확인 단계에서 실패해 키보드 수용 완료로 판정하지 않았다.
