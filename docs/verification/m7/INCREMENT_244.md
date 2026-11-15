# M7 Increment 244 — 속성 창의 권한·코드 서명 화면 대조

[Windows 원본 실행](https://github.com/taro6222/files-for-mac/actions/runs/43674401391)은 고정 원본 `99951c66928c4da714da8b1dd46039421182cbab`과 Windows 10.0.26100 AMD64에서 통과했다. 원본 앱의 [보안 화면](ui-09-windows-reference-security.png)에서 공통 파일 `preview.txt`의 사용자·그룹 목록, 선택한 주체의 허용·거부와 고급 권한 진입점을 확인했다. [서명 화면](ui-09-windows-reference-signatures.png)의 서명받은 주체는 Windows가 확인한 `Microsoft Corporation`과 일치했다. Windows PNG의 SHA-256 두 개를 실행 매니페스트와 대조했다.

Apple Silicon macOS 27.2의 영어·밝은 테마에서는 공통 파일의 별도 사본에 POSIX 모드 `0644`와 `everyone` 읽기 허용 ACL을 설정했다. [권한 시트](ui-09-macos-reference-security.png)는 소유자·그룹·기타 권한과 확장 ACL을 표시했다. 텍스트 파일은 서명되지 않음으로 표시됐다. 임시 Mach-O 사본의 ad-hoc 서명을 `codesign`으로 검증한 뒤 [코드 서명 영역](ui-09-macos-reference-signatures.png)에서 유효 상태, 식별자, 형식을 확인했다. 전체 AppKit 검사 310개가 통과했다.

Windows 캡처는 NTFS 주체별 권한과 Authenticode 인증서 정보를 보여 준다. macOS 캡처는 POSIX·확장 ACL과 Mach-O의 ad-hoc 서명 상태를 보여 준다. Windows의 고급 보안 화면, macOS 인증서 기반 서명 상태 및 중첩 번들 상태는 열린 항목이다.
