# M7 Increment 335 — 원격 진단 파일 보존

상태: CI 보존 규칙·로컬 검증 완료. 새 경로의 실제 원격 업로드 수용과 M7 출시는 미완료다.

직전 `cc0031b` [ARM 전체 AppKit 실행](https://github.com/taro6222/files-for-mac/actions/runs/45754750492)에서 네 언어/테마 조합 각각 전체 303개와 탭 경계 18개가 모두 통과했다. 기존에 실패했던 세션 복원·큰 창 경계 보정도 통과했다. 각 report.json의 실제 check 값과 해시를 확인했다. 이 결과는 해당 ARM 전체 AppKit 단계의 증거이며 전체 workflow·Intel·최신 소스의 수용을 대신하지 않는다.

아티팩트에는 새 desktop-session-comparison.json이 없었다. workflow가 report/progress JSON, run.log, 정해진 timeout-sample.txt와 PNG만 보존하고 있었기 때문이다. 새 Git 시간 초과 디렉터리와 기존 Git clone 스택 접두 파일도 이 목록에 포함되지 않았다. 원격 보고서에 없는 상세 값을 로컬 결과에서 가져와 채우지 않는다.

이제 언어/테마별 세션 비교 JSON, 루트의 git-clone-timeout-*.txt/log, git-window-timeout 내부 파일을 추가로 보존한다. 임의의 모든 하위 txt/log를 업로드하지 않으며 fixture 내용과 실행 스크립트는 제외한다. 이미 실행 중인 55c1bee 작업의 규칙을 소급 변경하지 않는다. 그 실행의 보고서 내 Git 상태 진단은 확인할 수 있지만 새 중첩 스택 보존은 후속 실행에서 확인해야 한다.

## 검증과 범위

Ruby safe YAML 파싱으로 실제 업로드 step의 경로 9개를 읽었다. 임시 트리에서 기대한 파일 11개가 모두 선택되고 fixture/private.txt와 별도 gate 스크립트가 제외되는지 확인했다. git diff --check도 통과했다. [규칙·소스 해시·ARM 보고서 해시](artifact-retention-335-verification.json).

앱 소스·패키지·Xcode 프로젝트는 기준 55c1bee와 같다. 전체 AppKit·Core·Release·볼륨·8시간을 다시 시작하지 않는다. 55c1bee 두 CPU Xcode 빌드는 성공했고 전체 AppKit과 Windows 압축 입력/취소 수집은 기존 실행을 유지한다. Intel 초기 Git 지연의 원인·해결, Windows 압축 수집, 8시간 메모리 안정성, 실제 입력/VoiceOver·지원 환경·외부 서비스·정식 서명/공증은 남아 있다. Mac 화면 잠금 해제 응답을 기다리며 인증서와 notarytool 프로필은 사용자 준비 중이다.
