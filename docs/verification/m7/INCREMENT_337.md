# M7 Increment 337 — 압축 저장 기본 이름 대응

상태: 구현·로컬 검증 완료. 새 소스 원격/후보 수용과 M7 정식 출시는 미완료다.

336단계 Windows 정상 화면의 이름은 preview.txt였다. [고정 원본 GetDestination](https://github.com/files-community/Files/blob/99951c66928c4da714da8b1dd46039421182cbab/src/Files.App/Actions/Content/Archives/Compress/BaseCompressArchiveAction.cs)은 단일 항목의 전체 파일명, 여러 항목이면 현재 폴더 이름을 기본값으로 사용한다. 원본은 이름과 압축 포맷을 별도 필드로 제공한다.

Mac 저장 패널은 단일 항목의 마지막 확장자를 지우고 .zip을 붙였고, 여러 항목이면 고정된 Archive.zip을 사용했다. 이제 전체 항목 이름 또는 현재 폴더 이름에 .zip을 붙인다. preview.txt는 preview.txt.zip, Folder.v1은 Folder.v1.zip, archive.zip은 archive.zip.zip이 된다. 기존 ZIP을 다시 압축할 때 원본과 같은 이름을 기본 제안하던 경우도 피한다. 루트 위치처럼 유효한 이름 부분이 없는 경우는 기존의 현지화된 압축 파일.zip/Archive.zip을 사용한다.

실제 메뉴 명령이 사용하는 NSSavePanel 생성기를 공유해 기본값을 검사한다. TXT·한글·점이 있는 폴더 이름·ZIP·복수 확장자, 여러 항목의 점이 있는 부모 폴더, 루트의 현지화된 대체 이름을 실제 패널의 nameFieldStringValue로 확인한다. 해당 검사는 최초 Git 조회 뒤 압축 검증 구간에서 수행해 현재 조사 중인 Git 첫 조회의 초기화 조건을 앞에서 바꾸지 않는다.

저장 위치 선택·허용 ZIP/7z 형식·사용자 편집·확인/취소 콜백과 압축 엔진은 유지한다. 원본 파일 변경·게시·취소·기존 대상 거부 정책을 바꾸지 않는다. 이 검증은 기본 패널 구성의 확인이며 실제 키보드/마우스 입력이나 Mac/Windows의 모든 입력 상태 수용을 의미하지 않는다.

네 언어/테마 조합의 전체 UI 각각 306개와 탭 경계 각각 18개, Debug·Release 빌드와 parity 구조 검사가 통과했다. Core·압축 엔진·파일 작업 코드를 바꾸지 않아 Core/볼륨 시험은 반복하지 않았다. [소스·바이너리·보고서 해시](archive-default-337-verification.json). a07c80c 프리뷰는 336단계에 기록한 고정 소스의 기존 이미지이며 이 새 변경이 포함됐다고 주장하지 않는다. 새 소스 원격·최신 후보 장시간·Intel Git snapshot 지연의 원인/해결·원격 스택 보존, 실제 입력/VoiceOver·지원 환경·외부 서비스·정식 서명/공증은 남아 있다. 인증서·notarytool 프로필은 사용자 준비 중이며 화면 잠금 해제 응답을 기다린다.


## 고정 Git 진단 실행

55c1bee ARM은 첫 한국어/밝음의 Git 창만 실패했고 다른 세 조합은 각각 303개, 경계는 네 조합 각각 18개가 통과했다. 10.033초 시점에는 창이 표시된 채 snapshot 단계·작업 실행 중·스냅샷 없음이었다. 부모 sample 종료 코드는 0이며 그 뒤 직접 Git 자식 검색은 1이었다. 이 값으로 원래 시점의 자식 부재나 정확한 원인을 단정하지 않는다. 스택 파일은 이전 업로드 목록 때문에 아티팩트에 없었다.

보완한 경로로 [05dd05d 스택 수집](https://github.com/taro6222/files-for-mac/actions/runs/45758991064)을 실행했다. 이 실행은 압축 패널 기본값 변경 전 소스를 유지하며 새 원격 파일을 확인해야 한다. 초기 snapshot 지연을 해결했다고 표시하지 않는다.
