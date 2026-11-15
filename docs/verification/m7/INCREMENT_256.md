# M7 Increment 256 — Windows 고급 보안 화면 실행 결과

Windows 11 빌드 26100 AMD64 러너에서 고정 원본 Files v4.2.9를 설치했다. 공통 파일 `preview.txt`에서 기본 보안과 고급 보안 화면을 열었다. 고급 화면의 소유자가 Windows ACL의 소유자와 일치했다. 내려받은 접근성 트리에서 참조 ACL 세 항목을 각각 대조했다. 화면에 보인 세 항목 모두 허용으로 일치했고, 그중 두 항목이 모든 권한으로 표시됐다. 두 PNG의 SHA-256을 실행의 캡처 기록과 대조했다. [화면과 접근성 트리](https://github.com/taro6222/files-for-mac/actions/runs/43676987642)

macOS 동선은 속성 창의 소유자 표시와 별도 POSIX 권한·확장 ACL 시트를 사용한다. [macOS 확장 ACL 편집 검증](INCREMENT_154.md)과 [두 앱의 기본 보안 화면 대조](INCREMENT_244.md)를 참조한다. 이 Windows 실행에서 고급 권한 편집·저장이나 거부 ACE는 시험하지 않았다. macOS 인증서 기반 서명 검증도 남아 있다.
