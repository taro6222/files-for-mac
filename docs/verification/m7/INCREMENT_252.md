# M7 Increment 252 — Windows 고급 보안 화면 검증

원본 캡처의 `advanced-security` 범위에서 공통 파일 `preview.txt`의 고급 권한을 연다. 러너에서 [Get-Acl](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-acl)로 파일 소유자와 권한 항목을 별도 JSON에 저장한다.

접근성 트리에서 고급 권한 목록과 소유자 표시 이름이 일치하고, 화면에 보이는 같은 행에서 주체와 허용·거부 값이 일치하는지 확인한다. 파일 ACL에서 모든 권한으로 분류된 항목에는 화면에도 모든 권한이 표시되어야 한다. 기존 보안 화면과 고급 보안 화면의 PNG와 접근성 트리를 저장한다.

Python 모의 시험으로 소유자, 주체, 효과, 모든 권한의 대조와 다른 행 또는 화면 밖의 항목이 사용되는 경우의 실패를 확인했다. 기존 속성·해시 및 보안·서명 모의 경로, YAML, 대응표 감사도 통과했다. 실제 화면은 Windows 원본 실행에서 확인한다.
