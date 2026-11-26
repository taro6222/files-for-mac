# 압축 생성 옵션 대응

기준은 [v4.2.9 고정 생성 창](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/CreateArchiveDialog.xaml)과 [같은 창의 ViewModel](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Dialogs/CreateArchiveDialog.xaml.cs)이다. 아래 표는 UI-13의 세부 요구사항이다. 기존 SETTINGS.csv 143개 행의 분류 완료를 이 옵션 전체의 구현 완료로 해석하지 않는다.

| 원본 동작 | 현재 macOS 구현 | 남은 검증 또는 구현 |
|---|---|---|
| 이름과 유효성 검사 | 원본과 같은 기본 이름 부분, NSSavePanel 이름/저장 위치 선택 | 양쪽 동일 입력 상태·크기·배율의 전체 대화상자 수용 |
| 포맷 선택 | ZIP·7z 명시적 선택, 확장자 및 엔진 판별 연결 | 원본의 추가 포맷 대응 및 선택 포맷의 설정 복원 |
| 압축 수준 | 여섯 수준을 엔진에 전달, 선택 저장·재개방·재기동 및 설정 가져오기 | 새 소스 원격 두 CPU, 전체 저장 창과 실제 입력 수용 |
| 분할 크기 | capability 미지원으로 기록 | 실제 분할 생성·볼륨 탐색·추출·누락 볼륨과 오류 복구 |
| 사전 크기 | 미구현 | 백엔드 옵션 연결·유효 조합·실제 출력 검증 |
| 워드 크기 | 미구현 | 백엔드 옵션 연결·유효 조합·실제 출력 검증 |
| CPU 스레드 | 미구현 | 백엔드 병렬 처리·범위·취소·자원 사용 검증 |
| 암호 및 암호 표시 | [ZIP AES-256 UI](../verification/m7/INCREMENT_342.md)의 생성·개별/혼합 일괄 추출·표시 전환·틀린 암호 재시도·취소·입력 정리 구현 및 로컬 검증. ZIP capability 활성화 | 독립 구현·최신 두 CPU·지원 OS·실제 입력 수용. 7z는 [351단계](../verification/m7/INCREMENT_351.md)에서 생성·파일 이름 암호화와 추출을 연결했으며 원격 UI 수용 대기. RAR 암호 지원 |
| 예상·사용 가능 메모리 | 미구현 | 선택 옵션별 근거 있는 추정·실제 자원 대조 |

사전 크기·워드 크기·분할 관련 컨트롤은 원본의 CanSplit에 따라 활성화된다. 비활성 컨트롤의 표시 자체와 백엔드 지원을 구분한다. 엔진 지원이 없는 옵션을 동작하는 것처럼 노출하지 않는다. 원본과의 차이는 열린 구현 항목이며 정식 출시 수용 완료로 처리하지 않는다.

압축 수준의 로컬 실행 근거는 [340단계](../verification/m7/INCREMENT_340.md)에 기록한다. 원본과 libarchive의 동일 이름 수준은 동일 알고리즘·출력 바이트·속도를 의미하지 않는다.

[344단계](../verification/m7/INCREMENT_344.md)에서 공식 도구의 한글 암호 7z·헤더 암호화·분할·64KiB 사전·워드/스레드 옵션 조합을 실행하고 실제 원문 복원을 확인했다. 제품의 SDK/게시·복구·UI 연결은 [7z 백엔드 계약](../SEVENZIP_BACKEND.md)에 따라 구현하며 위 미완료 항목은 유지한다. 같은 단계의 독립 AES ZIP 왕복은 로컬 ARM에서 확인했으며 다른 OS와 새 두 CPU 수용은 별도 진행한다.

[348단계](../verification/m7/INCREMENT_348.md)에서 SDK와 Swift 목록/추출 서비스를 ad-hoc 앱에 포함하고 실제 DMG 내부에서 실행했다. UI 선택·암호 7z 생성·분할·세부 옵션과 최신 지원 환경 수용은 남아 있으므로 위 capability/미완료 판정은 유지한다.

[351단계](../verification/m7/INCREMENT_351.md)는 7z 생성의 암호·파일 이름 암호화 선택·여섯 압축 수준을 SDK와 생성 화면에 연결한다. 원격 생성 화면 수용과 위 고급 옵션은 계속 열린 항목이다.
