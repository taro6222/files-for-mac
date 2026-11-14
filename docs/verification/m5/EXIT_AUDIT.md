# M5 외부 통합 종료 감사

감사일: 2026-11-14

M5 종료 조건은 압축·클라우드·원격·Git의 capability가 실제 동작과 일치하고, 오프라인·손상·인증·충돌 시험을 통과하는 것이다. 구현 완료와 환경 의존 수용을 분리해 기록한다.

| 영역 | 구현/자동 검증 | 환경 의존 수용 | 판정 |
|---|---|---|---|
| 압축 | ZIP/7z 생성·탐색·안전 추출, RAR 탐색·안전 추출, traversal/link/bomb 한도, 손상·취소·staging 정리, UI 4조합 | 암호·분할·수정은 capability false이며 UI에 제공하지 않음 | 지원 범위 통과 |
| 클라우드 | CloudStorage/iCloud 위치 탐지, unknown 보존, ubiquitous 항목만 다운로드·공간 비우기, 비지원 명령 무변경, UI 4조합 | 실제 iCloud 및 타사 File Provider의 placeholder·오프라인·취소·재실행 | 대기 |
| FTP | Unix/DOS 목록, 미지원 형식 차단, Keychain gate, staging 다운로드, rename capability probe, localhost 실제 전송 | 공개/인증 서버의 재인증·끊김·대용량 취소 | 대기 |
| FTPS | 암시적 TLS, 인증서 chain·hostname 검증, localhost 실제 TLS 연결 | 공개 CA 인증 서버 및 인증 실패/갱신 | 대기 |
| SFTP | pinned host key, security-scoped 개인키, private config, localhost OpenSSH 목록·다운로드·rename·mismatch·취소 | 실제 원격 host key 변경·재인증·agent/키 조합 | 대기 |
| SMB | Finder 표준 mount 위임, credential URL 비노출, 장착 볼륨 파일 작업 수용 스크립트 | 실제 SMB 서버 mount·재연결·권한·네트워크 단절 | 대기 |
| Git | 상태·브랜치·clone·fetch·FF-only pull·비강제 push, bare remote·divergence·취소·staging·UI 4조합, [루프백 OpenSSH 에이전트 인증](../m7/INCREMENT_109.md), [루프백 HTTPS와 macOS Keychain 인증](../m7/INCREMENT_110.md) | 외부 Git 서비스 로그인·토큰 갱신 | 대기 |

## 자동 검증 기준선

- Swift Testing 153개 통과
- 한국어/영어 × 밝게/어둡게 UI 4조합 통과
- localhost FTP·FTPS·OpenSSH 수용 통과
- Git local bare remote clone/fetch/pull/push·divergence 보존 통과
- ZIP/7z Unicode round-trip과 공식 7z/RAR fixture 통과

## 종료 판정

M5 코드는 지원한다고 표시한 로컬 자동 검증 범위에서 통과했다. 그러나 종료 조건에 인증 시험이 포함되어 있으므로 클라우드 공급자 계정, 공개 FTPS, 실제 SMB, 실제 SFTP, 인증 Git remote 증거가 없이는 M5를 완료로 표시하지 않는다.

이 외부 게이트는 M6의 독립적인 대응표·접근성·설정 정리 작업을 막지 않는다. M6 개발을 진행하되 최종 M7 출시 판정 전에는 반드시 실제 환경에서 재검증한다.
