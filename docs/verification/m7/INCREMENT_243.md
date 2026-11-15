# M7 Increment 243 — Windows 보안·서명 화면 검증

Windows 원본 캡처의 `security` 범위에서 공통 텍스트 파일의 속성을 열어 보안 화면의 사용자·그룹 목록과 고급 권한 컨트롤이 표시되는지 검사한다.

서명 화면은 Windows 러너에 설치된 실행 파일에서 유효한 내장 서명을 확인하고 시험 폴더에 복사해 검사한다. 파일의 SHA-256과 서명자 이름을 증거에 저장한다. 속성 화면의 서명받은 주체가 일치할 때 접근성 트리와 PNG를 저장한다. [Windows 서명 조회](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature)

Python 모의 응답으로 일반 속성·해시 경로, 새 보안·서명 경로, 서명자 불일치 시 실패를 확인했다. YAML 입력과 대응표 감사가 통과했다. [실제 원본 앱의 화면 결과](INCREMENT_244.md)에서 보안 목록과 서명받은 주체를 확인했다.
