# M6 Increment 52 — 시스템 설치·미디어 열기 명령

검증일: 2026-11-14

## 대응

- `InstallCertificate`는 `.cer`, `.crt`, `.der`, `.p12`, `.pfx`, `.pem` 선택에만 활성화하고 macOS Launch Services의 등록 처리기로 연다. 앱이 Keychain 신뢰 설정을 직접 변경하지 않으며 시스템 가져오기·암호·권한 확인 UI가 최종 결정을 소유한다.
- `InstallFont`는 `.ttf`, `.otf`, `.ttc`, `.dfont` 선택에만 활성화하고 Font Book 계열 시스템 처리기의 미리보기·설치 확인 흐름으로 연다. 앱이 사용자/시스템 글꼴 폴더에 직접 복사하지 않는다.
- `PlayAll`은 Uniform Type Identifier가 audio/movie/audiovisual content에 해당하는 선택만 허용하고 각 항목을 등록된 기본 미디어 앱으로 연다. 일부 항목 전달이 실패해도 나머지 선택은 계속 전달하고 오류를 알린다.
- 세 명령은 파일 메뉴·컨텍스트 메뉴·명령 팔레트에 등록한다.

## 검증 경계

- 인증서 신뢰 또는 글꼴 설치는 외부 시스템 UI의 명시적 사용자 확인이 필요하므로 자동 QA에서 실제 설치를 수행하지 않는다.
- 확장자/UTType 양성·음성 단위 테스트와 4개 UI 조합의 명령 등록을 자동 검증한다.

전체 Swift Testing 173개, AppKit UI 4개 조합 및 패리티 감사를 실행한다.
