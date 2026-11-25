# M7 Increment 293 — 실제 Swift 내용 검색 fixture와 원격 회귀 결과

[소스 3a65d40의 Intel 전체 AppKit 실행](https://github.com/taro6222/files-for-mac/actions/runs/45629049035)에서 한국어·영어 × 밝게·어둡게가 각각 283개를 통과했다. 이전에 실패한 자동 폴더 크기와 상세 목록 요청도 네 조합 모두 21바이트와 목록 준비 상태를 확인했다. 설치 프리뷰 생성·설치·기동 단계도 통과했다. [원본 UI 보고서](full-appkit-3a65d40-intel.json). 같은 실행의 Apple Silicon은 색인이 활성 상태임에도 체크아웃의 Swift 소스가 검색되지 않아 Spotlight 준비 단계에서 실패했다. 전체 워크플로를 통과로 판정하지 않는다.

Spotlight 준비를 재현 가능한 전용 fixture로 바꿨다. 홈의 고유 시험 폴더 아래에 `Sources/FilesCore/LocalSearch.swift`를 원본 바이트 그대로 복사하고 SHA-256을 대조한다. 같은 Swift 타입·파일명·중첩 경로·`SearchRouter` 내용 조건을 사용하며 실제 `mdfind` 결과가 해당 파일과 같은 identity인지 확인한다. UI 검사는 준비된 물리 검색 경로를 사용하고 기존 283개 항목과 범위 조건을 유지한다. 수용 조건을 줄이거나 제한 시간을 늘리지 않았다.

추가한 DEBUG 검증은 제품의 `NSMetadataQuery` 어댑터로 하위 폴더의 정확한 Swift 파일 발견, 현재 폴더에서 중첩 파일 제외, 다른 현재 폴더에서도 전체 색인으로 정확한 파일 발견, 알 수 없는 내용의 결과 없음을 확인한다. macOS 27.2.1(26B131)에서 네 조건을 통과했다. [색인·검색·정리 증거와 실행 파일/소스 해시](spotlight-fixture-macos27.2.1.json). 로컬의 전역 색인 설정은 변경하지 않았다. 실패 시 importer·파일 타입·색인 상태를 남기며 CI에서 증거를 보존한다.

준비·검색·전체 UI 실행 후 고유 폴더를 정리한다. 폴더 identity와 소유 표시, 파일 목록·원본 해시를 확인하며 다른 파일이 추가되면 삭제를 거부한다. 로컬에서 별도 sentinel 추가 시 그대로 보존됐고, 시험이 만든 sentinel을 제거한 뒤 소유 fixture만 정리됐다. 최종 준비와 네이티브 검증을 다시 실행한 fixture도 정리했다.

로컬 재현: `python3 scripts/prepare-spotlight-fixture.py prepare`, `python3 scripts/verify-spotlight-fixture.py --binary .build/debug/FilesMac`, `python3 scripts/prepare-spotlight-fixture.py cleanup`. CI의 색인 활성 설정 옵션은 폐기되는 GitHub Actions runner에서만 허용한다. 새 준비 방식의 원격 두 CPU 전체 UI 결과는 후속 실행으로 판정한다.

[파일 약속 송신 소스 1eac741의 CI](https://github.com/taro6222/files-for-mac/actions/runs/45632931359)에서 두 CPU의 AppKit 제공자 계약이 각각 18개를 통과했다. [원본 제공자 계약 보고서](file-promise-contract-1eac741-ci.json). 이 결과는 실제 마우스 드래그나 파일 약속 수신의 수용을 증명하지 않는다. 로컬 콘솔은 잠금 상태이며 F17 수신 구현과 실제 드래그 검증, 원본 UI 대응·지원 OS 검증·8시간 시험·서명과 공증이 남아 있다.
