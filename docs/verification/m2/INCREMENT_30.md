# M2 서른 번째 개발 단위 검증 — APFS·APFSX·exFAT 볼륨 매트릭스

검증일: 2026-11-13

## 재현 가능한 실제 볼륨 시험

`scripts/verify-volume-matrix.sh`는 `/tmp`에 프로젝트 전용 이미지를 만들고 다음 세 볼륨을 실제 마운트한다.

- APFS
- 대소문자 구분 APFS
- exFAT

각 볼륨에서 Unicode 폴더 복사·SHA-256 내용 검증·복사 Undo, 256KiB 교차 볼륨 이동·이동 Undo, 기존 대상 교체 백업·교체 Undo, 파일 이름 대소문자 의미를 검사한다. 종료·실패·인터럽트 시 trap이 역순으로 이미지를 분리하고 `/tmp` 파일을 삭제한다. 검증 후 관련 마운트가 남지 않았음을 확인했다.

## 발견하고 수정한 결함

1. APFS 소스와 exFAT 대상의 POSIX 권한 비트가 달라 정상 복사를 손상으로 오판했다.
   - 소스 변경 탐지는 권한 포함 snapshot으로 유지한다.
   - 교차 파일 시스템 내용 무결성은 항목 유형, 심볼릭 링크 대상, SHA-256으로 비교한다.
   - Undo는 게시된 대상의 실제 메타데이터 snapshot을 기록한다.
2. exFAT은 `renameatx_np(RENAME_EXCL)`을 지원하지 않았다.
   - APFS 계열은 기존 descriptor-relative 원자 게시를 유지한다.
   - 미지원 파일 시스템에서만 대상 부재를 no-follow로 다시 검사한 뒤 `FileManager.moveItem`의 비교체 계약을 사용한다.
   - 실패 전후 대상이 존재하면 충돌로 처리해 외부 항목을 보존한다.
   - 같은 fallback을 교체 이동의 숨김 백업에도 적용했다.

## 결과와 경계

- 세 실제 볼륨의 복사·이동·교체·각 Undo 및 대소문자 검사가 통과했다.
- 전체 Swift Testing 77개와 `FilesMac` 빌드가 통과했다. 환경 변수가 없는 일반 테스트에서는 외부 볼륨 테스트가 안전하게 조기 반환하며, 실제 매트릭스 통과 주장은 전용 스크립트 실행 결과에만 근거한다.
- SMB는 실제 서버가 없어 검증하지 않았고, exFAT fallback은 APFS의 `RENAME_EXCL`과 동일한 syscall 원자성을 주장하지 않는다.
