# M7 Increment 238 — Windows 일반 속성·해시 실행 화면

[Windows 재시험](https://github.com/taro6222/files-for-mac/actions/runs/43670496723)이 통과했다. 고정 원본 `99951c66928c4da714da8b1dd46039421182cbab`을 Windows 10.0.26100 AMD64에 설치해 공통 시험 파일 `preview.txt`의 속성 창을 열었다. [일반 화면](ui-09-windows-reference-general.png)에서 파일명, 경로, 24바이트 크기와 날짜를 확인했다.

[해시 화면](ui-09-windows-reference-hashes.png)은 CRC32, MD5, SHA-1, SHA-256을 표시한다. 캡처의 접근성 트리에서 읽은 전체 SHA-256 값 `f288c2f02342069c184b6d162f982144eb504f03c2f30c23d1a420f9e5fb780a`가 시험 파일의 24바이트로 계산한 값과 일치했다. 두 PNG의 SHA-256을 실행 매니페스트와 대조했다.

macOS는 [별도 AppKit 시험](INCREMENT_152.md)에서 여섯 알고리즘과 값·파일 비교를 검증했다. [같은 파일을 연 macOS 실행 화면](INCREMENT_240.md)에서 논리 크기와 SHA-256을 대조했다. Windows 보안·서명 상태 대조는 남아 있다.
